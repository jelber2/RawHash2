/**
 * rlive.cpp — Real-time MinKNOW/Icarust gRPC signal streaming for RawHash2.
 *
 * Connects to MinKNOW's DataService.get_live_reads() bidirectional streaming
 * RPC, receives signal chunks per channel, and processes each chunk
 * incrementally using ri_map_one_chunk() — preserving mapping state (anchors,
 * events, normalization statistics) across chunks for the same read.
 *
 * Supports both CALIBRATED (float32, default) and UNCALIBRATED (int16) modes.
 * UNCALIBRATED mode fetches per-channel calibration from DeviceService.
 *
 * Build requirement: ENABLE_GRPC=ON (cmake -DENABLE_GRPC=ON ..)
 * Runtime requirement: a running MinKNOW or Icarust gRPC server
 */

#ifndef NGRPCRH

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <memory>
#include <chrono>

#include <grpcpp/grpcpp.h>
#include "minknow_api/data.grpc.pb.h"
#include "minknow_api/device.grpc.pb.h"

/* C headers (with extern "C" linkage) */
extern "C" {
#include "rlive.h"
#include "rmap.h"
#include "kthread.h"
#include "kalloc.h"
#include "rutils.h"
}

using minknow_api::data::DataService;
using minknow_api::data::GetLiveReadsRequest;
using minknow_api::data::GetLiveReadsResponse;
using minknow_api::device::DeviceService;
using minknow_api::device::GetCalibrationRequest;
using minknow_api::device::GetCalibrationResponse;

/* ========================================================================
 * Per-channel calibration (for UNCALIBRATED mode)
 * ======================================================================== */

typedef struct ri_channel_cal_s {
	float offset;       /* ADC offset for this channel */
	float scale;        /* pa_range / digitisation */
	int valid;          /* 1 if calibration data was fetched */
} ri_channel_cal_t;

/* ========================================================================
 * Per-channel state for incremental chunk processing
 * ======================================================================== */

typedef struct ri_channel_state_s {
	uint32_t channel_id;     /* 1-indexed channel number */
	char *read_id;           /* current read UUID string (heap-allocated) */
	uint8_t read_active;     /* 1 if a read is in progress */

	/* Signal buffer for current chunk (calibrated + filtered pA) */
	float *chunk_sig;
	uint32_t l_chunk_sig;    /* valid samples in current chunk */
	uint32_t m_chunk_sig;    /* allocated capacity */

	/* Persistent mapping state across chunks for same read */
	ri_reg1_t *reg;          /* anchors, offset, events, chains, maps */
	ri_tbuf_t *buf;          /* thread-local memory pool */
	double mean_sum;         /* cumulative normalization statistics */
	double std_dev_sum;
	uint32_t n_events_sum;
	uint32_t chunk_count;    /* chunks processed for this read */
	uint8_t mapping_done;    /* 1 = mapped or max chunks reached */
	double t_start;          /* mapping start time for this read */
	uint32_t read_rid;       /* numeric read id for output */

	/* For finalization (read_length reporting) */
	uint32_t total_samples;  /* total raw samples received for this read */
} ri_channel_state_t;

static void init_channel_mapping_state(ri_channel_state_t *ch, uint32_t rid)
{
	ch->reg = (ri_reg1_t *)calloc(1, sizeof(ri_reg1_t));
	ch->reg->prev_anchors = NULL;
	ch->reg->creg = NULL;
	ch->reg->events = NULL;
	ch->reg->offset = 0;
	ch->reg->n_prev_anchors = 0;
	ch->reg->n_cregs = 0;
	ch->reg->n_maps = 0;
	ch->reg->maps = NULL;

	ch->buf = ri_tbuf_init_live();
	ch->mean_sum = 0;
	ch->std_dev_sum = 0;
	ch->n_events_sum = 0;
	ch->chunk_count = 0;
	ch->mapping_done = 0;
	ch->t_start = ri_realtime();
	ch->read_rid = rid;
	ch->total_samples = 0;
}

static void cleanup_channel_mapping_state(ri_channel_state_t *ch)
{
	if (ch->reg) {
		ri_map_cleanup(ch->reg, ch->buf);
		if (ch->reg->maps) { free(ch->reg->maps); ch->reg->maps = NULL; }
		free(ch->reg);
		ch->reg = NULL;
	}
	if (ch->buf) {
		ri_tbuf_destroy_live(ch->buf);
		ch->buf = NULL;
	}
}

static void reset_channel_state(ri_channel_state_t *ch)
{
	cleanup_channel_mapping_state(ch);
	if (ch->read_id) { free(ch->read_id); ch->read_id = NULL; }
	ch->read_active = 0;
	ch->mapping_done = 0;
	ch->chunk_count = 0;
	ch->total_samples = 0;
	/* Note: chunk_sig buffer is retained (reused) for the next read */
}

/* ========================================================================
 * PAF output for a single read (reusable for both mapped and unmapped)
 * ======================================================================== */

static void output_paf(const ri_idx_t *idx, ri_reg1_t *reg)
{
	if (!reg || !reg->read_name) return;

	if (reg->n_maps > 0 && reg->maps[0].mapped) {
		for (uint32_t m = 0; m < reg->n_maps; ++m) {
			if (reg->maps[m].ref_id < idx->n_seq) {
				fprintf(stdout,
				        "%s\t%u\t%u\t%u\t%c\t%s\t%u\t%u\t%u\t%u\t%u\t%u\t%s\n",
				        reg->read_name,
				        reg->maps[m].read_length,
				        reg->maps[m].read_start_position,
				        reg->maps[m].read_end_position,
				        reg->maps[m].rev ? '-' : '+',
				        (idx->flag & RI_I_SIG_TARGET)
				            ? idx->sig[reg->maps[m].ref_id].name
				            : idx->seq[reg->maps[m].ref_id].name,
				        (idx->flag & RI_I_SIG_TARGET)
				            ? idx->sig[reg->maps[m].ref_id].l_sig
				            : idx->seq[reg->maps[m].ref_id].len,
				        reg->maps[m].fragment_start_position,
				        reg->maps[m].fragment_start_position
				            + reg->maps[m].fragment_length,
				        reg->maps[m].read_end_position
				            - reg->maps[m].read_start_position - 1,
				        reg->maps[m].fragment_length,
				        reg->maps[m].mapq,
				        reg->maps[m].tags ? reg->maps[m].tags : "");
			}
			if (reg->maps[m].tags) {
				free(reg->maps[m].tags);
				reg->maps[m].tags = NULL;
			}
		}
	} else {
		/* Unmapped read */
		fprintf(stdout, "%s\t%u\t*\t*\t*\t*\t*\t*\t*\t*\t*\t%u\t%s\n",
		        reg->read_name,
		        reg->maps[0].read_length,
		        reg->maps[0].mapq,
		        reg->maps[0].tags ? reg->maps[0].tags : "");
		if (reg->maps[0].tags) {
			free(reg->maps[0].tags);
			reg->maps[0].tags = NULL;
		}
	}
	fflush(stdout);
}

/* ========================================================================
 * Decision feedback placeholder
 * ======================================================================== */

/**
 * Placeholder for adaptive sequencing decision feedback.
 * Called after mapping decision is made for a read.
 *
 * Current behavior:
 *   - If mapped (n_maps > 0): send UnblockAction (eject the read)
 *   - If unmapped: do nothing (continue sequencing fully)
 */
static void ri_live_send_decision(
    grpc::ClientReaderWriter<GetLiveReadsRequest, GetLiveReadsResponse> *stream,
    uint32_t channel_id,
    const char *read_id,
    int n_maps)
{
	if (n_maps <= 0) {
		/* Unmapped: keep sequencing, no action */
		return;
	}

	/* Mapped: send unblock (eject) action */
	GetLiveReadsRequest action_req;
	auto *actions = action_req.mutable_actions();
	auto *action = actions->add_actions();
	action->set_action_id("rh2_eject_" + std::string(read_id));
	action->set_channel(channel_id);
	action->set_id(read_id);
	auto *unblock = action->mutable_unblock();
	unblock->set_duration(0.1);  /* short unblock duration */

	if (stream) {
		stream->Write(action_req);
		fprintf(stderr, "[M::%s] Sent unblock for ch=%u read=%s\n",
		        __func__, channel_id, read_id);
	}
}

/* ========================================================================
 * MinKNOW gRPC Client
 * ======================================================================== */

class MinKNOWClient {
public:
	explicit MinKNOWClient(const ri_live_opt_t *live_opt)
		: live_opt_(live_opt) {}

	~MinKNOWClient() { shutdown(); }

	bool connect()
	{
		std::string target = std::string(live_opt_->host) + ":"
		                   + std::to_string(live_opt_->port);

		if (live_opt_->use_tls && live_opt_->tls_cert_path) {
			FILE *fp = fopen(live_opt_->tls_cert_path, "r");
			if (!fp) {
				fprintf(stderr, "[E::%s] Cannot open TLS certificate: %s\n",
				        __func__, live_opt_->tls_cert_path);
				return false;
			}
			fseek(fp, 0, SEEK_END);
			long len = ftell(fp);
			fseek(fp, 0, SEEK_SET);
			std::string cert(len, '\0');
			if ((long)fread(&cert[0], 1, len, fp) != len) {
				fprintf(stderr, "[E::%s] Failed to read TLS certificate\n", __func__);
				fclose(fp);
				return false;
			}
			fclose(fp);

			grpc::SslCredentialsOptions ssl_opts;
			ssl_opts.pem_root_certs = cert;
			channel_ = grpc::CreateChannel(target, grpc::SslCredentials(ssl_opts));
		} else {
			channel_ = grpc::CreateChannel(target,
			                               grpc::InsecureChannelCredentials());
		}

		fprintf(stderr, "[M::%s] Connecting to %s ...\n", __func__, target.c_str());

		auto deadline = std::chrono::system_clock::now() + std::chrono::seconds(10);
		if (!channel_->WaitForConnected(deadline)) {
			fprintf(stderr, "[E::%s] Connection to %s timed out\n",
			        __func__, target.c_str());
			return false;
		}

		data_stub_ = DataService::NewStub(channel_);
		stream_ = data_stub_->get_live_reads(&context_);
		if (!stream_) {
			fprintf(stderr, "[E::%s] Failed to open get_live_reads stream\n",
			        __func__);
			return false;
		}

		fprintf(stderr, "[M::%s] Connected to %s\n", __func__, target.c_str());
		return true;
	}

	bool send_setup(uint32_t first_ch, uint32_t last_ch,
	                uint64_t min_chunk_size, bool uncalibrated)
	{
		GetLiveReadsRequest request;
		auto *setup = request.mutable_setup();
		setup->set_first_channel(first_ch);
		setup->set_last_channel(last_ch);
		setup->set_raw_data_type(uncalibrated
			? GetLiveReadsRequest::UNCALIBRATED
			: GetLiveReadsRequest::CALIBRATED);
		setup->set_sample_minimum_chunk_size(min_chunk_size);

		if (!stream_->Write(request)) {
			fprintf(stderr, "[E::%s] Failed to send StreamSetup\n", __func__);
			return false;
		}

		fprintf(stderr, "[M::%s] StreamSetup sent: channels %u-%u, "
		        "%s, min_chunk=%lu\n",
		        __func__, first_ch, last_ch,
		        uncalibrated ? "UNCALIBRATED" : "CALIBRATED",
		        (unsigned long)min_chunk_size);
		return true;
	}

	/**
	 * Fetch per-channel calibration from DeviceService (for UNCALIBRATED mode).
	 * Returns false if the service is unavailable (e.g., Icarust).
	 */
	bool fetch_calibration(uint32_t first_ch, uint32_t last_ch,
	                       ri_channel_cal_t *cal, uint32_t n_channels)
	{
		auto device_stub = DeviceService::NewStub(channel_);
		if (!device_stub) return false;

		GetCalibrationRequest req;
		req.set_first_channel(first_ch);
		req.set_last_channel(last_ch);

		GetCalibrationResponse resp;
		grpc::ClientContext ctx;
		auto deadline = std::chrono::system_clock::now() + std::chrono::seconds(5);
		ctx.set_deadline(deadline);

		grpc::Status status = device_stub->get_calibration(&ctx, req, &resp);
		if (!status.ok()) {
			fprintf(stderr, "[W::%s] DeviceService.get_calibration() failed: %s\n",
			        __func__, status.error_message().c_str());
			return false;
		}

		uint32_t digitisation = resp.digitisation();
		if (digitisation == 0) digitisation = 1; /* avoid div-by-zero */

		for (uint32_t i = 0; i < n_channels; ++i) {
			if ((int)i < resp.offsets_size() && (int)i < resp.pa_ranges_size()) {
				cal[i].offset = resp.offsets(i);
				cal[i].scale = resp.pa_ranges(i) / (float)digitisation;
				cal[i].valid = 1;
			} else {
				cal[i].valid = 0;
			}
		}

		fprintf(stderr, "[M::%s] Calibration fetched: digitisation=%u, %d channels\n",
		        __func__, digitisation, resp.offsets_size());
		return true;
	}

	bool read_response(GetLiveReadsResponse *response)
	{
		return stream_->Read(response);
	}

	/** Get the raw stream pointer for sending actions back. */
	grpc::ClientReaderWriter<GetLiveReadsRequest, GetLiveReadsResponse> *
	get_stream() { return stream_.get(); }

	void shutdown()
	{
		if (stream_) {
			stream_->WritesDone();
			context_.TryCancel();
			grpc::Status status = stream_->Finish();
			if (!status.ok() &&
			    status.error_code() != grpc::StatusCode::CANCELLED) {
				fprintf(stderr, "[W::%s] Stream finished with error: %s\n",
				        __func__, status.error_message().c_str());
			}
			stream_.reset();
		}
	}

private:
	const ri_live_opt_t *live_opt_;
	std::shared_ptr<grpc::Channel> channel_;
	std::unique_ptr<DataService::Stub> data_stub_;
	grpc::ClientContext context_;
	std::unique_ptr<grpc::ClientReaderWriter<
		GetLiveReadsRequest, GetLiveReadsResponse>> stream_;
};

/* ========================================================================
 * Public API
 * ======================================================================== */

extern "C" void ri_live_opt_init(ri_live_opt_t *opt)
{
	memset(opt, 0, sizeof(ri_live_opt_t));
	opt->host = (char *)"localhost";
	opt->port = 10001;
	opt->first_channel = 1;
	opt->last_channel = 512;
	opt->use_tls = 0;
	opt->tls_cert_path = NULL;
	opt->duration_seconds = 0;
	opt->debug = 0;
	opt->no_sig_filter = 0;
	opt->uncalibrated = 0;
}

extern "C" int ri_map_live(const ri_idx_t *idx,
                           const ri_mapopt_t *opt,
                           const ri_live_opt_t *live_opt,
                           int n_threads)
{
	(void)n_threads; /* sequential per-channel processing for now */

	/* Connect to MinKNOW/Icarust */
	MinKNOWClient client(live_opt);
	if (!client.connect()) return -1;
	if (!client.send_setup(live_opt->first_channel, live_opt->last_channel,
	                       opt->chunk_size, live_opt->uncalibrated)) {
		return -1;
	}

	/* Allocate per-channel state */
	uint32_t n_channels = live_opt->last_channel - live_opt->first_channel + 1;
	ri_channel_state_t *channels = (ri_channel_state_t *)calloc(
		n_channels, sizeof(ri_channel_state_t));
	for (uint32_t i = 0; i < n_channels; ++i)
		channels[i].channel_id = live_opt->first_channel + i;

	/* Fetch per-channel calibration if UNCALIBRATED mode */
	ri_channel_cal_t *cal = NULL;
	int has_device_cal = 0;
	if (live_opt->uncalibrated) {
		cal = (ri_channel_cal_t *)calloc(n_channels, sizeof(ri_channel_cal_t));
		has_device_cal = client.fetch_calibration(
			live_opt->first_channel, live_opt->last_channel,
			cal, n_channels) ? 1 : 0;
		if (!has_device_cal) {
			fprintf(stderr, "[W::%s] DeviceService unavailable, using Icarust "
			        "R10 defaults for calibration (offset=-243, scale=0.1462)\n",
			        __func__);
		}
	}

	/* Icarust R10 fallback calibration constants */
	const float ICARUST_R10_OFFSET = -243.0f;
	const float ICARUST_R10_SCALE = 0.14620706f;

	uint32_t n_processed = 0;
	uint64_t total_chunks_received = 0;
	uint64_t total_reads_mapped = 0;
	uint64_t total_reads_unmapped = 0;
	uint32_t max_chunk = opt->max_num_chunk;

	double t_start = ri_realtime();

	fprintf(stderr, "[M::%s] Entering incremental live streaming loop "
	        "(channels %u-%u, max_chunk=%u, chunk_size=%u)\n",
	        __func__, live_opt->first_channel, live_opt->last_channel,
	        max_chunk, opt->chunk_size);

	GetLiveReadsResponse response;
	while (client.read_response(&response)) {
		total_chunks_received++;

		for (auto &kv : response.channels()) {
			uint32_t ch_num = kv.first;
			const auto &read_data = kv.second;

			if (ch_num < live_opt->first_channel ||
			    ch_num > live_opt->last_channel)
				continue;

			uint32_t ch_idx = ch_num - live_opt->first_channel;
			ri_channel_state_t *ch = &channels[ch_idx];
			const std::string &read_id_str = read_data.id();

			/* Debug mode: just print chunk metadata */
			if (live_opt->debug) {
				uint32_t n_samples = (uint32_t)(read_data.raw_data().size()
				                                / sizeof(float));
				fprintf(stderr, "[D::%s] ch=%u read=%s samples=%u "
				        "chunk_start=%lu chunk_len=%lu\n",
				        __func__, ch_num, read_id_str.c_str(),
				        n_samples,
				        (unsigned long)read_data.chunk_start_sample(),
				        (unsigned long)read_data.chunk_length());
				continue;
			}

			/* ---- Read boundary detection ---- */
			if (ch->read_active && ch->read_id &&
			    read_id_str != ch->read_id) {
				/* Previous read ended — finalize if not already done */
				if (!ch->mapping_done && ch->reg) {
					double mapping_time = ri_realtime() - ch->t_start;
					uint32_t c_count = (ch->chunk_count > 0) ? ch->chunk_count - 1 : 0;
					ri_map_finalize(idx, opt, ch->reg, ch->buf,
					                ch->read_rid, ch->read_id,
					                ch->total_samples, c_count,
					                opt->chunk_size, mapping_time);
					output_paf(idx, ch->reg);
					ri_live_send_decision(client.get_stream(),
					                      ch->channel_id, ch->read_id,
					                      ch->reg->n_maps);
					if (ch->reg->n_maps > 0 && ch->reg->maps[0].mapped)
						total_reads_mapped++;
					else
						total_reads_unmapped++;
				}
				reset_channel_state(ch);
			}

			/* ---- Start new read if needed ---- */
			if (!ch->read_active) {
				ch->read_id = strdup(read_id_str.c_str());
				ch->read_active = 1;
				init_channel_mapping_state(ch, n_processed++);
			}

			/* ---- Skip if mapping already decided for this read ---- */
			if (ch->mapping_done) continue;

			/* ---- Extract and calibrate signal ---- */
			const std::string &raw = read_data.raw_data();
			uint64_t chunk_len = read_data.chunk_length();
			if (raw.empty() || chunk_len == 0) continue;

			uint32_t n_new_samples;
			bool is_i16 = (raw.size() == chunk_len * sizeof(int16_t));

			if (is_i16) {
				n_new_samples = (uint32_t)(raw.size() / sizeof(int16_t));
			} else {
				n_new_samples = (uint32_t)(raw.size() / sizeof(float));
			}
			if (n_new_samples == 0) continue;

			/* Grow chunk buffer if needed */
			if (n_new_samples > ch->m_chunk_sig) {
				ch->m_chunk_sig = n_new_samples * 2;
				if (ch->m_chunk_sig < 16384) ch->m_chunk_sig = 16384;
				ch->chunk_sig = (float *)realloc(ch->chunk_sig,
				                                 ch->m_chunk_sig * sizeof(float));
			}

			if (is_i16) {
				const int16_t *raw_i16 =
					reinterpret_cast<const int16_t *>(raw.data());

				float cal_off, cal_scl;
				if (live_opt->uncalibrated && has_device_cal &&
				    cal[ch_idx].valid) {
					/* Real MinKNOW UNCALIBRATED: per-channel from DeviceService */
					cal_off = cal[ch_idx].offset;
					cal_scl = cal[ch_idx].scale;
				} else {
					/* Icarust or fallback: hardcoded R10 defaults */
					cal_off = ICARUST_R10_OFFSET;
					cal_scl = ICARUST_R10_SCALE;
				}

				for (uint32_t s = 0; s < n_new_samples; ++s) {
					ch->chunk_sig[s] =
						((float)raw_i16[s] + cal_off) * cal_scl;
				}
			} else {
				/* Float32 data (MinKNOW CALIBRATED) — copy directly */
				const float *new_sig =
					reinterpret_cast<const float *>(raw.data());
				memcpy(ch->chunk_sig, new_sig,
				       n_new_samples * sizeof(float));
			}

			/* ---- Apply pA range filter (30-200 pA) unless disabled ---- */
			if (!live_opt->no_sig_filter) {
				uint32_t filtered = 0;
				for (uint32_t s = 0; s < n_new_samples; ++s) {
					float pa = ch->chunk_sig[s];
					if (pa > 30.0f && pa < 200.0f) {
						ch->chunk_sig[filtered++] = pa;
					}
				}
				n_new_samples = filtered;
			}

			if (n_new_samples == 0) continue;

			ch->total_samples += n_new_samples;
			ch->l_chunk_sig = n_new_samples;

			/* ---- Process chunk incrementally ---- */
			int mapped = ri_map_one_chunk(
				idx, opt,
				(const float *)ch->chunk_sig, n_new_samples,
				ch->reg, ch->buf,
				&ch->mean_sum, &ch->std_dev_sum,
				&ch->n_events_sum, ch->read_id);

			ch->chunk_count++;

			if (mapped) {
				/* Mapping found — finalize and output */
				double mapping_time = ri_realtime() - ch->t_start;
				uint32_t c_count = (ch->chunk_count > 0) ? ch->chunk_count - 1 : 0;
				ri_map_finalize(idx, opt, ch->reg, ch->buf,
				                ch->read_rid, ch->read_id,
				                ch->total_samples, c_count,
				                opt->chunk_size, mapping_time);
				output_paf(idx, ch->reg);
				ri_live_send_decision(client.get_stream(),
				                      ch->channel_id, ch->read_id,
				                      ch->reg->n_maps);
				ch->mapping_done = 1;
				total_reads_mapped++;

				fprintf(stderr, "[M::%s] ch=%u read=%s MAPPED after %u chunks "
				        "(%.3f sec)\n",
				        __func__, ch->channel_id, ch->read_id,
				        ch->chunk_count, ri_realtime() - ch->t_start);
			} else if (ch->chunk_count >= max_chunk) {
				/* Max chunks reached — finalize as unmapped */
				double mapping_time = ri_realtime() - ch->t_start;
				uint32_t c_count = ch->chunk_count - 1;
				ri_map_finalize(idx, opt, ch->reg, ch->buf,
				                ch->read_rid, ch->read_id,
				                ch->total_samples, c_count,
				                opt->chunk_size, mapping_time);
				output_paf(idx, ch->reg);
				ri_live_send_decision(client.get_stream(),
				                      ch->channel_id, ch->read_id,
				                      ch->reg->n_maps);
				ch->mapping_done = 1;
				if (ch->reg->n_maps > 0 && ch->reg->maps[0].mapped)
					total_reads_mapped++;
				else
					total_reads_unmapped++;
			}
		}

		/* Check duration limit */
		if (live_opt->duration_seconds > 0) {
			double elapsed = ri_realtime() - t_start;
			if (elapsed >= live_opt->duration_seconds) {
				fprintf(stderr, "[M::%s] Duration limit reached (%.1f sec)\n",
				        __func__, elapsed);
				break;
			}
		}
	}

	/* Finalize any remaining active reads */
	for (uint32_t i = 0; i < n_channels; ++i) {
		ri_channel_state_t *ch = &channels[i];
		if (ch->read_active && !ch->mapping_done && ch->reg) {
			double mapping_time = ri_realtime() - ch->t_start;
			uint32_t c_count = (ch->chunk_count > 0) ? ch->chunk_count - 1 : 0;
			ri_map_finalize(idx, opt, ch->reg, ch->buf,
			                ch->read_rid, ch->read_id,
			                ch->total_samples, c_count,
			                opt->chunk_size, mapping_time);
			output_paf(idx, ch->reg);
			if (ch->reg->n_maps > 0 && ch->reg->maps[0].mapped)
				total_reads_mapped++;
			else
				total_reads_unmapped++;
		}
	}

	/* Cleanup */
	client.shutdown();
	for (uint32_t i = 0; i < n_channels; ++i) {
		cleanup_channel_mapping_state(&channels[i]);
		if (channels[i].chunk_sig) free(channels[i].chunk_sig);
		if (channels[i].read_id) free(channels[i].read_id);
	}
	free(channels);
	if (cal) free(cal);

	double total_time = ri_realtime() - t_start;
	fprintf(stderr, "[M::%s] Live streaming finished: %.1f sec, "
	        "%lu responses, %lu mapped, %lu unmapped, %u total reads\n",
	        __func__, total_time,
	        (unsigned long)total_chunks_received,
	        (unsigned long)total_reads_mapped,
	        (unsigned long)total_reads_unmapped,
	        n_processed);

	return 0;
}

#endif /* NGRPCRH */
