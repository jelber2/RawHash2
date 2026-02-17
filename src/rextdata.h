#ifndef REXTDATA_H
#define REXTDATA_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Entry for a single read's external peak positions.
 * peaks: array of segmentation boundary indices (in raw signal space)
 * n_peaks: number of peaks
 */
typedef struct ri_ext_peaks_entry_s {
	uint32_t *peaks;
	uint32_t n_peaks;
} ri_ext_peaks_entry_t;

/**
 * Entry for a single read's external event values.
 * events: array of pre-computed event values (float)
 * n_events: number of events
 */
typedef struct ri_ext_events_entry_s {
	float *events;
	uint32_t n_events;
} ri_ext_events_entry_t;

/* Opaque handle types (khash internally) */
typedef void ri_ext_peaks_t;
typedef void ri_ext_events_t;

/**
 * Load external peaks file.
 * Format: one read per line, tab/space separated.
 *   Column 1: read_id (UUID string)
 *   Remaining columns: uint32 peak positions (raw signal indices)
 *   Lines starting with '#' are skipped.
 *
 * @param fname  path to peaks file
 * @return       opaque handle, or NULL on failure
 */
ri_ext_peaks_t *ri_load_ext_peaks(const char *fname);

/**
 * Load move table file and convert to peak positions.
 * Format: one read per line, tab separated.
 *   Column 1: read_id
 *   Column 2: mv:B:c,STRIDE,m0,m1,...,mN  (move table from BAM)
 *   Column 3: ts:i:OFFSET  (template start from BAM)
 *   Lines starting with '#' are skipped.
 *
 * Conversion: moves are expanded using stride and template_start
 * to produce raw-signal peak positions, stored as ext_peaks entries.
 *
 * @param fname  path to moves file
 * @return       opaque ext_peaks handle, or NULL on failure
 */
ri_ext_peaks_t *ri_load_ext_moves(const char *fname);

/**
 * Load external events file.
 * Format: one read per line, tab/space separated.
 *   Column 1: read_id (UUID string)
 *   Remaining columns: float event values
 *   Lines starting with '#' are skipped.
 *
 * @param fname  path to events file
 * @return       opaque handle, or NULL on failure
 */
ri_ext_events_t *ri_load_ext_events(const char *fname);

/**
 * Look up external peaks for a read.
 * @return  pointer to entry, or NULL if read not found
 */
const ri_ext_peaks_entry_t *ri_lookup_ext_peaks(const ri_ext_peaks_t *h, const char *read_id);

/**
 * Look up external events for a read.
 * @return  pointer to entry, or NULL if read not found
 */
const ri_ext_events_entry_t *ri_lookup_ext_events(const ri_ext_events_t *h, const char *read_id);

/** Free external peaks data */
void ri_destroy_ext_peaks(ri_ext_peaks_t *h);

/** Free external events data */
void ri_destroy_ext_events(ri_ext_events_t *h);

#ifdef __cplusplus
}
#endif

#endif /* REXTDATA_H */
