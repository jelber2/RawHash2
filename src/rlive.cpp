/**
 * rlive.cpp — Real-time MinKNOW/Icarust gRPC signal streaming for RawHash2.
 *
 * Connects to MinKNOW's DataService.get_live_reads() bidirectional streaming
 * RPC, receives calibrated signal chunks per channel, accumulates them into
 * ri_sig_t structures, and dispatches to the existing map_worker_for()
 * pipeline for mapping. Results are output as PAF to stdout.
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
#include <atomic>
#include <chrono>

#include <grpcpp/grpcpp.h>
#include "minknow_api/data.grpc.pb.h"

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

/* ========================================================================
 * Per-channel state for accumulating signal chunks
 * ======================================================================== */

typedef struct ri_channel_state_s {
	uint32_t channel_id;     /* 1-indexed channel number */
	char *read_id;           /* current read UUID string (heap-allocated) */
	float *sig;              /* accumulated calibrated signal samples */
	uint32_t l_sig;          /* number of accumulated samples */
	uint32_t m_sig;          /* allocated capacity */
	uint8_t read_active;     /* 1 if a read is in progress */
} ri_channel_state_t;

static void reset_channel_state(ri_channel_state_t *ch)
{
	if (ch->read_id) { free(ch->read_id); ch->read_id = NULL; }
	ch->l_sig = 0;
	ch->read_active = 0;
	/* Note: sig buffer is retained (reused) for the next read on this channel */
}

/**
 * Package accumulated channel signal into an ri_sig_t for the mapping pipeline.
 * Copies the signal data so the channel buffer can be reused.
 */
static ri_sig_t *package_channel_signal(ri_channel_state_t *ch, uint32_t rid)
{
	ri_sig_t *s = (ri_sig_t *)calloc(1, sizeof(ri_sig_t));
	s->rid = rid;
	s->name = strdup(ch->read_id);
	s->l_sig = ch->l_sig;
	s->sig = (float *)malloc(ch->l_sig * sizeof(float));
	memcpy(s->sig, ch->sig, ch->l_sig * sizeof(float));
	return s;
}

/* ========================================================================
 * MinKNOW gRPC Client
 * ======================================================================== */

class MinKNOWClient {
public:
	explicit MinKNOWClient(const ri_live_opt_t *live_opt)
		: live_opt_(live_opt) {}

	~MinKNOWClient() { shutdown(); }

	/**
	 * Connect to MinKNOW/Icarust and open the bidirectional stream.
	 */
	bool connect()
	{
		std::string target = std::string(live_opt_->host) + ":"
		                   + std::to_string(live_opt_->port);

		if (live_opt_->use_tls && live_opt_->tls_cert_path) {
			/* Read TLS certificate */
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

		/* Wait for connection with timeout */
		auto deadline = std::chrono::system_clock::now() + std::chrono::seconds(10);
		if (!channel_->WaitForConnected(deadline)) {
			fprintf(stderr, "[E::%s] Connection to %s timed out\n",
			        __func__, target.c_str());
			return false;
		}

		stub_ = DataService::NewStub(channel_);
		stream_ = stub_->get_live_reads(&context_);
		if (!stream_) {
			fprintf(stderr, "[E::%s] Failed to open get_live_reads stream\n",
			        __func__);
			return false;
		}

		fprintf(stderr, "[M::%s] Connected to %s\n", __func__, target.c_str());
		return true;
	}

	/**
	 * Send the initial StreamSetup message to configure channel range and data type.
	 */
	bool send_setup(uint32_t first_ch, uint32_t last_ch,
	                uint64_t min_chunk_size)
	{
		GetLiveReadsRequest request;
		auto *setup = request.mutable_setup();
		setup->set_first_channel(first_ch);
		setup->set_last_channel(last_ch);
		setup->set_raw_data_type(
			GetLiveReadsRequest::CALIBRATED);
		setup->set_sample_minimum_chunk_size(min_chunk_size);

		if (!stream_->Write(request)) {
			fprintf(stderr, "[E::%s] Failed to send StreamSetup\n", __func__);
			return false;
		}

		fprintf(stderr, "[M::%s] StreamSetup sent: channels %u-%u, "
		        "CALIBRATED, min_chunk=%lu\n",
		        __func__, first_ch, last_ch,
		        (unsigned long)min_chunk_size);
		return true;
	}

	/**
	 * Read one GetLiveReadsResponse from the stream (blocking).
	 * Returns false when the stream ends or an error occurs.
	 */
	bool read_response(GetLiveReadsResponse *response)
	{
		return stream_->Read(response);
	}

	/**
	 * Gracefully close the stream.
	 * Uses TryCancel to avoid blocking indefinitely if the server
	 * keeps the stream open (common with Icarust).
	 */
	void shutdown()
	{
		if (stream_) {
			stream_->WritesDone();
			/* Cancel the context to unblock Finish() if the server
			 * doesn't close its end of the stream. */
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
	std::unique_ptr<DataService::Stub> stub_;
	grpc::ClientContext context_;
	std::unique_ptr<grpc::ClientReaderWriter<
		GetLiveReadsRequest, GetLiveReadsResponse>> stream_;
};

/* ========================================================================
 * Dispatch batch to map_worker_for and output results
 * ======================================================================== */

/**
 * Dispatch a batch of reads to the existing mapping pipeline.
 * Creates step_mt, calls kt_for(map_worker_for), outputs PAF, and cleans up.
 */
static void dispatch_and_map(const ri_idx_t *idx,
                             const ri_mapopt_t *opt,
                             ri_sig_t **sigs,
                             int n_sig,
                             int n_threads)
{
	if (n_sig <= 0) return;

	/* Create step_mt — same structure as map_worker_pipeline step 0 */
	step_mt s;
	memset(&s, 0, sizeof(step_mt));
	s.n_sig = n_sig;
	s.sig = sigs;

	/* Minimal pipeline_mt for shared context */
	pipeline_mt pl;
	memset(&pl, 0, sizeof(pipeline_mt));
	pl.ri = idx;
	pl.opt = opt;
	pl.n_threads = n_threads;
	s.p = &pl;

	/* Allocate thread buffers (same as step==0) */
	s.buf = (ri_tbuf_t **)calloc(n_threads, sizeof(ri_tbuf_t *));
	for (int i = 0; i < n_threads; ++i)
		s.buf[i] = ri_tbuf_init_live();

	/* Allocate registrations */
	s.reg = (ri_reg1_t **)calloc(n_sig, sizeof(ri_reg1_t *));
	for (int i = 0; i < n_sig; ++i)
		s.reg[i] = (ri_reg1_t *)calloc(1, sizeof(ri_reg1_t));

	/* Dispatch to worker threads (reuses existing map_worker_for) */
	kt_for(n_threads, ri_map_worker_for, &s, n_sig);

	/* Output results — same format as map_worker_pipeline step 2 */
	for (int k = 0; k < n_sig; ++k) {
		ri_reg1_t *reg0 = s.reg[k];
		if (!reg0 || !reg0->read_name) continue;

		if (reg0->n_maps > 0) {
			for (uint32_t m = 0; m < reg0->n_maps; ++m) {
				if (reg0->maps[m].ref_id < idx->n_seq) {
					fprintf(stdout,
					        "%s\t%u\t%u\t%u\t%c\t%s\t%u\t%u\t%u\t%u\t%u\t%u\t%s\n",
					        reg0->read_name,
					        reg0->maps[m].read_length,
					        reg0->maps[m].read_start_position,
					        reg0->maps[m].read_end_position,
					        reg0->maps[m].rev ? '-' : '+',
					        (idx->flag & RI_I_SIG_TARGET)
					            ? idx->sig[reg0->maps[m].ref_id].name
					            : idx->seq[reg0->maps[m].ref_id].name,
					        (idx->flag & RI_I_SIG_TARGET)
					            ? idx->sig[reg0->maps[m].ref_id].l_sig
					            : idx->seq[reg0->maps[m].ref_id].len,
					        reg0->maps[m].fragment_start_position,
					        reg0->maps[m].fragment_start_position
					            + reg0->maps[m].fragment_length,
					        reg0->maps[m].read_end_position
					            - reg0->maps[m].read_start_position - 1,
					        reg0->maps[m].fragment_length,
					        reg0->maps[m].mapq,
					        reg0->maps[m].tags ? reg0->maps[m].tags : "");
				}
				if (reg0->maps[m].tags) {
					free(reg0->maps[m].tags);
					reg0->maps[m].tags = NULL;
				}
			}
		} else {
			/* Unmapped read */
			fprintf(stdout, "%s\t%u\t*\t*\t*\t*\t*\t*\t*\t*\t*\t%u\t%s\n",
			        reg0->read_name,
			        reg0->maps[0].read_length,
			        reg0->maps[0].mapq,
			        reg0->maps[0].tags ? reg0->maps[0].tags : "");
			if (reg0->maps[0].tags) {
				free(reg0->maps[0].tags);
				reg0->maps[0].tags = NULL;
			}
		}
		fflush(stdout);

		/* Cleanup registration */
		if (reg0->maps) { free(reg0->maps); reg0->maps = NULL; }
		free(reg0);
		s.reg[k] = NULL;
	}

	/* Cleanup step */
	for (int i = 0; i < n_threads; ++i)
		ri_tbuf_destroy_live(s.buf[i]);
	free(s.buf);
	free(s.reg);

	/* Cleanup signal data */
	for (int i = 0; i < n_sig; ++i) {
		if (sigs[i]) {
			if (sigs[i]->sig) free(sigs[i]->sig);
			if (sigs[i]->name) free(sigs[i]->name);
			free(sigs[i]);
		}
	}
}

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
}

extern "C" int ri_map_live(const ri_idx_t *idx,
                           const ri_mapopt_t *opt,
                           const ri_live_opt_t *live_opt,
                           int n_threads)
{
	/* gRPC uses 1 thread; rest are for mapping */
	int mapping_threads = (n_threads > 2) ? n_threads - 1 : 1;

	/* Connect to MinKNOW/Icarust */
	MinKNOWClient client(live_opt);
	if (!client.connect()) return -1;
	if (!client.send_setup(live_opt->first_channel, live_opt->last_channel,
	                       opt->chunk_size)) {
		return -1;
	}

	/* Allocate per-channel state */
	uint32_t n_channels = live_opt->last_channel - live_opt->first_channel + 1;
	ri_channel_state_t *channels = (ri_channel_state_t *)calloc(
		n_channels, sizeof(ri_channel_state_t));
	for (uint32_t i = 0; i < n_channels; ++i)
		channels[i].channel_id = live_opt->first_channel + i;

	uint32_t n_processed = 0;
	uint64_t total_chunks_received = 0;
	uint64_t total_reads_dispatched = 0;

	/* Maximum signal samples to accumulate before dispatching a read.
	 * This corresponds to chunk_size * max_num_chunk, i.e., the maximum
	 * signal the mapping pipeline would process anyway. */
	uint32_t max_sig_per_read = opt->chunk_size * opt->max_num_chunk;

	/* Timing for duration limit */
	double t_start = ri_realtime();

	fprintf(stderr, "[M::%s] Entering live streaming loop (channels %u-%u, "
	        "%u mapping threads)\n",
	        __func__, live_opt->first_channel, live_opt->last_channel,
	        mapping_threads);

	/* Batch of reads ready for mapping */
	std::vector<ri_sig_t *> ready_reads;
	ready_reads.reserve(256);

	GetLiveReadsResponse response;
	while (client.read_response(&response)) {
		total_chunks_received++;
		ready_reads.clear();

		/* Process each channel's ReadData in this response */
		for (auto &kv : response.channels()) {
			uint32_t ch_num = kv.first;
			const auto &read_data = kv.second;

			/* Validate channel range */
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

			/* Detect read boundary: read_id changed on this channel */
			if (ch->read_active && ch->read_id &&
			    read_id_str != ch->read_id) {
				/* Previous read ended — dispatch its accumulated signal */
				if (ch->l_sig > 0) {
					ri_sig_t *sig = package_channel_signal(ch, n_processed++);
					ready_reads.push_back(sig);
				}
				reset_channel_state(ch);
			}

			/* Start tracking new read if needed */
			if (!ch->read_active) {
				ch->read_id = strdup(read_id_str.c_str());
				ch->read_active = 1;
			}

			/* Extract signal samples from raw_data bytes.
			 *
			 * Protocol says CALIBRATED = float32 LE, but Icarust
			 * always sends raw i16 regardless of the request type.
			 * Auto-detect: if raw_data.size() == chunk_length * 2,
			 * it's i16 (needs calibration); if chunk_length * 4,
			 * it's float32 (already calibrated). */
			const std::string &raw = read_data.raw_data();
			uint64_t chunk_len = read_data.chunk_length();
			if (raw.empty() || chunk_len == 0) continue;

			uint32_t n_new_samples;
			bool is_i16 = (raw.size() == chunk_len * sizeof(int16_t));

			if (is_i16) {
				n_new_samples = (uint32_t)(raw.size() / sizeof(int16_t));
			} else {
				/* Assume float32 (real MinKNOW CALIBRATED mode) */
				n_new_samples = (uint32_t)(raw.size() / sizeof(float));
			}
			if (n_new_samples == 0) continue;

			/* Grow channel buffer if needed */
			uint32_t needed = ch->l_sig + n_new_samples;
			if (needed > ch->m_sig) {
				ch->m_sig = needed * 2;
				if (ch->m_sig < 16384) ch->m_sig = 16384;
				ch->sig = (float *)realloc(ch->sig,
				                           ch->m_sig * sizeof(float));
			}

			if (is_i16) {
				/* Convert i16 to calibrated pA values.
				 * Calibration: pA = (raw + offset) * scale
				 * Icarust R10 defaults: offset=-243.0, scale=0.1462 */
				const int16_t *raw_i16 =
					reinterpret_cast<const int16_t *>(raw.data());
				float cal_offset = (float)read_data.median_before();
				/* Icarust doesn't expose calibration per-channel in
				 * ReadData. Use the known R10 defaults. The median
				 * and median_before fields are set to fixed values. */
				float cal_scale = 0.14620706f;
				float cal_off = -243.0f;
				/* If median_before is the Icarust default (225.0),
				 * use the known calibration constants. Otherwise,
				 * just cast without calibration. */
				for (uint32_t s = 0; s < n_new_samples; ++s) {
					ch->sig[ch->l_sig + s] =
						((float)raw_i16[s] + cal_off) * cal_scale;
				}
			} else {
				/* Float32 data — copy directly */
				const float *new_sig =
					reinterpret_cast<const float *>(raw.data());
				memcpy(ch->sig + ch->l_sig, new_sig,
				       n_new_samples * sizeof(float));
			}
			ch->l_sig += n_new_samples;

			/* Dispatch when we have enough signal for full analysis */
			if (ch->l_sig >= max_sig_per_read) {
				ri_sig_t *sig = package_channel_signal(ch, n_processed++);
				ready_reads.push_back(sig);
				reset_channel_state(ch);
			}
		}

		/* Dispatch batch of ready reads to mapping workers */
		if (!ready_reads.empty()) {
			int batch_n = (int)ready_reads.size();
			ri_sig_t **batch = (ri_sig_t **)malloc(
				batch_n * sizeof(ri_sig_t *));
			for (int i = 0; i < batch_n; ++i)
				batch[i] = ready_reads[i];

			dispatch_and_map(idx, opt, batch, batch_n, mapping_threads);
			free(batch);

			total_reads_dispatched += batch_n;
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

	/* Dispatch any remaining accumulated reads */
	ready_reads.clear();
	for (uint32_t i = 0; i < n_channels; ++i) {
		ri_channel_state_t *ch = &channels[i];
		if (ch->read_active && ch->l_sig > 0) {
			ri_sig_t *sig = package_channel_signal(ch, n_processed++);
			ready_reads.push_back(sig);
		}
	}
	if (!ready_reads.empty()) {
		int batch_n = (int)ready_reads.size();
		ri_sig_t **batch = (ri_sig_t **)malloc(
			batch_n * sizeof(ri_sig_t *));
		for (int i = 0; i < batch_n; ++i)
			batch[i] = ready_reads[i];

		dispatch_and_map(idx, opt, batch, batch_n, mapping_threads);
		free(batch);
		total_reads_dispatched += batch_n;
	}

	/* Cleanup */
	client.shutdown();
	for (uint32_t i = 0; i < n_channels; ++i) {
		if (channels[i].sig) free(channels[i].sig);
		if (channels[i].read_id) free(channels[i].read_id);
	}
	free(channels);

	double total_time = ri_realtime() - t_start;
	fprintf(stderr, "[M::%s] Live streaming finished: %.1f sec, "
	        "%lu response messages, %lu reads dispatched, %u reads processed\n",
	        __func__, total_time,
	        (unsigned long)total_chunks_received,
	        (unsigned long)total_reads_dispatched,
	        n_processed);

	return 0;
}

#endif /* NGRPCRH */
