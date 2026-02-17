#include "rextdata.h"
#include "khash.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* khash instantiations for string -> peaks/events mappings */
KHASH_MAP_INIT_STR(ext_peaks, ri_ext_peaks_entry_t)
KHASH_MAP_INIT_STR(ext_events, ri_ext_events_entry_t)

/* Maximum line length for external data files (1 MB).
 * A read with 10,000 peaks at ~7 chars each needs ~70 KB. */
#define REXTDATA_LINE_BUF_SIZE (1024 * 1024)

ri_ext_peaks_t *ri_load_ext_peaks(const char *fname)
{
	FILE *fp = fopen(fname, "r");
	if (!fp) return NULL;

	khash_t(ext_peaks) *h = kh_init(ext_peaks);
	char *line = (char*)malloc(REXTDATA_LINE_BUF_SIZE);
	uint32_t n_reads = 0;

	while (fgets(line, REXTDATA_LINE_BUF_SIZE, fp)) {
		/* skip comments and empty lines */
		if (line[0] == '#' || line[0] == '\n' || line[0] == '\r') continue;

		/* strip trailing newline */
		size_t len = strlen(line);
		while (len > 0 && (line[len-1] == '\n' || line[len-1] == '\r')) line[--len] = '\0';
		if (len == 0) continue;

		/* first token: read ID */
		char *saveptr = NULL;
		char *token = strtok_r(line, " \t", &saveptr);
		if (!token) continue;

		char *read_id = strdup(token);

		/* parse peak positions into dynamic array */
		uint32_t cap = 1024, n = 0;
		uint32_t *peaks = (uint32_t*)malloc(cap * sizeof(uint32_t));

		while ((token = strtok_r(NULL, " \t", &saveptr)) != NULL) {
			if (n >= cap) {
				cap *= 2;
				peaks = (uint32_t*)realloc(peaks, cap * sizeof(uint32_t));
			}
			peaks[n++] = (uint32_t)strtoul(token, NULL, 10);
		}

		/* shrink to fit */
		if (n > 0)
			peaks = (uint32_t*)realloc(peaks, n * sizeof(uint32_t));
		else {
			free(peaks);
			peaks = NULL;
		}

		/* insert into hash map */
		int ret;
		khiter_t k = kh_put(ext_peaks, h, read_id, &ret);
		if (ret == 0) {
			/* duplicate read ID — replace old entry */
			free((char*)kh_key(h, k));
			free(kh_val(h, k).peaks);
			kh_key(h, k) = read_id;
		}
		kh_val(h, k).peaks = peaks;
		kh_val(h, k).n_peaks = n;
		n_reads++;
	}

	free(line);
	fclose(fp);
	fprintf(stderr, "[M::%s] loaded %u reads from peaks file '%s'\n", __func__, n_reads, fname);
	return (ri_ext_peaks_t*)h;
}

ri_ext_peaks_t *ri_load_ext_moves(const char *fname)
{
	FILE *fp = fopen(fname, "r");
	if (!fp) return NULL;

	khash_t(ext_peaks) *h = kh_init(ext_peaks);
	char *line = (char*)malloc(REXTDATA_LINE_BUF_SIZE);
	uint32_t n_reads = 0;

	while (fgets(line, REXTDATA_LINE_BUF_SIZE, fp)) {
		/* skip comments and empty lines */
		if (line[0] == '#' || line[0] == '\n' || line[0] == '\r') continue;

		/* strip trailing newline */
		size_t len = strlen(line);
		while (len > 0 && (line[len-1] == '\n' || line[len-1] == '\r')) line[--len] = '\0';
		if (len == 0) continue;

		/* Split into tab-separated columns:
		 *   col1: read_id
		 *   col2: mv:B:c,STRIDE,m0,m1,...,mN
		 *   col3: ts:i:OFFSET
		 */
		char *saveptr = NULL;
		char *col1 = strtok_r(line, "\t", &saveptr);
		char *col2 = strtok_r(NULL, "\t", &saveptr);
		char *col3 = strtok_r(NULL, "\t", &saveptr);
		if (!col1 || !col2 || !col3) continue;

		char *read_id = strdup(col1);

		/* Parse mv:B:c,STRIDE,m0,m1,...,mN
		 * Skip the "mv:B:c," prefix (7 chars), then first comma-value is stride */
		char *mv_data = col2;
		if (strncmp(mv_data, "mv:B:c,", 7) != 0) {
			free(read_id);
			continue;
		}
		mv_data += 7; /* now points to "STRIDE,m0,m1,..." */

		char *mv_saveptr = NULL;
		char *mv_tok = strtok_r(mv_data, ",", &mv_saveptr);
		if (!mv_tok) { free(read_id); continue; }

		uint32_t stride = (uint32_t)strtoul(mv_tok, NULL, 10);
		if (stride == 0) { free(read_id); continue; }

		/* Parse remaining comma-separated move values into temporary buffer */
		uint32_t mv_cap = 4096, n_moves = 0;
		int8_t *moves = (int8_t*)malloc(mv_cap * sizeof(int8_t));

		while ((mv_tok = strtok_r(NULL, ",", &mv_saveptr)) != NULL) {
			if (n_moves >= mv_cap) {
				mv_cap *= 2;
				moves = (int8_t*)realloc(moves, mv_cap * sizeof(int8_t));
			}
			moves[n_moves++] = (int8_t)atoi(mv_tok);
		}

		/* Parse ts:i:OFFSET — skip "ts:i:" prefix (5 chars) */
		char *ts_data = col3;
		if (strncmp(ts_data, "ts:i:", 5) != 0) {
			free(read_id);
			free(moves);
			continue;
		}
		uint32_t template_start = (uint32_t)strtoul(ts_data + 5, NULL, 10);

		/* Convert moves to peak positions using UNCALLED4/squigualiser algorithm:
		 *   start = template_start
		 *   end = start + stride
		 *   for i = 1..N:
		 *     if moves[i] == 1: record peak at "end" (boundary), start = end
		 *     end += stride
		 *
		 * moves[0] is always 1 (first base start) — we skip it.
		 * Each subsequent "1" marks a segmentation boundary (peak).
		 *
		 * We insert template_start as the FIRST peak to separate the
		 * adapter/trim region (signal[0:ts]) from the genomic signal.
		 * This way gen_events() produces:
		 *   Event 0 = mean(signal[0:ts]) — adapter noise (harmless, gets filtered)
		 *   Event 1+ = proper k-mer segments starting from template_start */
		uint32_t pk_cap = 1024, n_peaks = 0;
		uint32_t *peaks = (uint32_t*)malloc(pk_cap * sizeof(uint32_t));

		/* First peak = template_start to separate adapter from genomic signal */
		peaks[n_peaks++] = template_start;

		uint32_t end = template_start + stride;

		for (uint32_t i = 1; i < n_moves; i++) {
			if (moves[i] == 1) {
				if (n_peaks >= pk_cap) {
					pk_cap *= 2;
					peaks = (uint32_t*)realloc(peaks, pk_cap * sizeof(uint32_t));
				}
				peaks[n_peaks++] = end; /* boundary where new segment starts */
			}
			end += stride;
		}

		free(moves);

		/* shrink to fit */
		if (n_peaks > 0)
			peaks = (uint32_t*)realloc(peaks, n_peaks * sizeof(uint32_t));
		else {
			free(peaks);
			peaks = NULL;
		}

		/* insert into hash map */
		int ret;
		khiter_t k = kh_put(ext_peaks, h, read_id, &ret);
		if (ret == 0) {
			/* duplicate read ID — replace old entry */
			free((char*)kh_key(h, k));
			free(kh_val(h, k).peaks);
			kh_key(h, k) = read_id;
		}
		kh_val(h, k).peaks = peaks;
		kh_val(h, k).n_peaks = n_peaks;
		n_reads++;
	}

	free(line);
	fclose(fp);
	fprintf(stderr, "[M::%s] loaded %u reads from moves file '%s'\n", __func__, n_reads, fname);
	return (ri_ext_peaks_t*)h;
}

ri_ext_events_t *ri_load_ext_events(const char *fname)
{
	FILE *fp = fopen(fname, "r");
	if (!fp) return NULL;

	khash_t(ext_events) *h = kh_init(ext_events);
	char *line = (char*)malloc(REXTDATA_LINE_BUF_SIZE);
	uint32_t n_reads = 0;

	while (fgets(line, REXTDATA_LINE_BUF_SIZE, fp)) {
		/* skip comments and empty lines */
		if (line[0] == '#' || line[0] == '\n' || line[0] == '\r') continue;

		/* strip trailing newline */
		size_t len = strlen(line);
		while (len > 0 && (line[len-1] == '\n' || line[len-1] == '\r')) line[--len] = '\0';
		if (len == 0) continue;

		/* first token: read ID */
		char *saveptr = NULL;
		char *token = strtok_r(line, " \t", &saveptr);
		if (!token) continue;

		char *read_id = strdup(token);

		/* parse event values into dynamic array */
		uint32_t cap = 1024, n = 0;
		float *events = (float*)malloc(cap * sizeof(float));

		while ((token = strtok_r(NULL, " \t", &saveptr)) != NULL) {
			if (n >= cap) {
				cap *= 2;
				events = (float*)realloc(events, cap * sizeof(float));
			}
			events[n++] = strtof(token, NULL);
		}

		/* shrink to fit */
		if (n > 0)
			events = (float*)realloc(events, n * sizeof(float));
		else {
			free(events);
			events = NULL;
		}

		/* insert into hash map */
		int ret;
		khiter_t k = kh_put(ext_events, h, read_id, &ret);
		if (ret == 0) {
			/* duplicate read ID — replace old entry */
			free((char*)kh_key(h, k));
			free(kh_val(h, k).events);
			kh_key(h, k) = read_id;
		}
		kh_val(h, k).events = events;
		kh_val(h, k).n_events = n;
		n_reads++;
	}

	free(line);
	fclose(fp);
	fprintf(stderr, "[M::%s] loaded %u reads from events file '%s'\n", __func__, n_reads, fname);
	return (ri_ext_events_t*)h;
}

const ri_ext_peaks_entry_t *ri_lookup_ext_peaks(const ri_ext_peaks_t *h, const char *read_id)
{
	if (!h || !read_id) return NULL;
	const khash_t(ext_peaks) *ht = (const khash_t(ext_peaks)*)h;
	khiter_t k = kh_get(ext_peaks, ht, read_id);
	if (k == kh_end(ht)) return NULL;
	return &kh_val(ht, k);
}

const ri_ext_events_entry_t *ri_lookup_ext_events(const ri_ext_events_t *h, const char *read_id)
{
	if (!h || !read_id) return NULL;
	const khash_t(ext_events) *ht = (const khash_t(ext_events)*)h;
	khiter_t k = kh_get(ext_events, ht, read_id);
	if (k == kh_end(ht)) return NULL;
	return &kh_val(ht, k);
}

void ri_destroy_ext_peaks(ri_ext_peaks_t *h)
{
	if (!h) return;
	khash_t(ext_peaks) *ht = (khash_t(ext_peaks)*)h;
	khiter_t k;
	for (k = kh_begin(ht); k != kh_end(ht); ++k) {
		if (!kh_exist(ht, k)) continue;
		free((char*)kh_key(ht, k));
		free(kh_val(ht, k).peaks);
	}
	kh_destroy(ext_peaks, ht);
}

void ri_destroy_ext_events(ri_ext_events_t *h)
{
	if (!h) return;
	khash_t(ext_events) *ht = (khash_t(ext_events)*)h;
	khiter_t k;
	for (k = kh_begin(ht); k != kh_end(ht); ++k) {
		if (!kh_exist(ht, k)) continue;
		free((char*)kh_key(ht, k));
		free(kh_val(ht, k).events);
	}
	kh_destroy(ext_events, ht);
}
