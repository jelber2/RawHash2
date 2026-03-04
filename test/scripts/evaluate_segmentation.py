#!/usr/bin/env python3
"""Evaluate segmentation quality via signal-level concordance.

Measures how well segmentation borders (peaks or moves) produce events whose
mean signal levels match the expected k-mer levels from a pore model. If
borders are placed correctly, the mean signal in each segment should match the
model's expected level for that k-mer.

Inputs:
  --pod5         Raw signal source (file or directory)
  --bam          Aligned BAM (to know the reference k-mer at each position)
  --peaks        Peaks file (rawhash2 --peaks-file format) OR
  --moves        Moves TSV file (rawhash2 --moves-file format)
  --level-table  K-mer level table (pore model)
  --output       Per-read metrics TSV

Output TSV columns:
  read_id  n_events  pearson_r  mean_l1  mapq  align_len  signal_len
"""

import os
import sys
import argparse
import pod5
import pysam
import numpy as np
from scipy import stats
from tqdm import tqdm


def get_pod5_readers(pod5_path):
    """Build a dict mapping read_id -> pod5.Reader."""
    read_reader_map = {}
    if pod5_path.endswith('.pod5'):
        reader = pod5.Reader(pod5_path)
        for rid in reader.read_ids:
            read_reader_map[str(rid)] = reader
        return read_reader_map
    for fname in os.listdir(pod5_path):
        if fname.endswith('.pod5'):
            reader = pod5.Reader(os.path.join(pod5_path, fname))
            for rid in reader.read_ids:
                read_reader_map[str(rid)] = reader
    return read_reader_map


def load_level_table(path):
    """Load k-mer level table. Returns dict {kmer: level_mean}.

    Supports two formats:
    - No header: kmer<TAB>level_mean (R10.4.1 9-mer model)
    - With header: kmer<TAB>level_mean<TAB>... (R9.4 6-mer model)
    """
    kmer_levels = {}
    with open(path) as f:
        first_line = f.readline().strip()
        parts = first_line.split('\t')
        if parts[0] == 'kmer':
            pass  # header line
        else:
            kmer_levels[parts[0]] = float(parts[1])
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            parts = line.split('\t')
            kmer_levels[parts[0]] = float(parts[1])
    return kmer_levels


def load_peaks_file(path):
    """Load peaks file. Returns dict {read_id: np.array of peak positions}."""
    peaks = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            parts = line.split('\t')
            read_id = parts[0]
            peak_positions = np.array([int(p) for p in parts[1:]], dtype=np.int64)
            peaks[read_id] = peak_positions
    return peaks


def load_moves_file(path):
    """Load moves TSV file and convert to peak positions.

    Returns dict {read_id: np.array of peak positions in raw signal space}.
    """
    peaks = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            parts = line.split('\t')
            read_id = parts[0]
            mv_str = parts[1]  # mv:B:c,STRIDE,0,1,...
            ts_str = parts[2]  # ts:i:OFFSET

            mv_parts = mv_str.split(',')
            stride = int(mv_parts[1])
            moves = [int(x) for x in mv_parts[2:]]
            ts_offset = int(ts_str.split(':')[2])

            peak_positions = []
            for i, m in enumerate(moves):
                if m == 1:
                    peak_positions.append(ts_offset + i * stride)
            peak_positions.append(ts_offset + len(moves) * stride)

            peaks[read_id] = np.array(peak_positions, dtype=np.int64)
    return peaks


_COMP = str.maketrans('ACGT', 'TGCA')


def _revcomp(seq):
    return seq.translate(_COMP)[::-1]


def get_ref_seq_from_bam(bam_read):
    """Extract the reference sequence spanned by this alignment.

    For reverse-strand reads, returns the reverse complement so that the
    sequence follows the same direction as the signal (5'->3' of the read).
    This matches what Remora uses internally for ref_to_signal.

    Returns (ref_seq, min_rpos) or (None, None).
    """
    pairs = bam_read.get_aligned_pairs(with_seq=True)
    ref_bases = {}
    for qpos, rpos, rbase in pairs:
        if rpos is not None and rbase is not None:
            ref_bases[rpos] = rbase.upper()

    if not ref_bases:
        return None, None

    min_rpos = min(ref_bases.keys())
    max_rpos = max(ref_bases.keys())
    ref_seq = ''.join(ref_bases.get(p, 'N') for p in range(min_rpos, max_rpos + 1))

    if bam_read.is_reverse:
        ref_seq = _revcomp(ref_seq)

    return ref_seq, min_rpos


def evaluate_read(signal, peaks, ref_seq, kmer_levels, kmer_size, center_idx):
    """Evaluate segmentation quality for a single read.

    Peaks come from ref_to_signal (ref-mapping mode) or query_to_signal
    (query-mapping mode). In either case, peaks[i] is the signal position
    for the i-th base in the sequence that produced them. For ref-mapping,
    this is the reference sequence directly; for query-mapping, peaks
    correspond to basecalled bases which we map to reference via CIGAR
    (handled by the caller).

    For ref-mapping peaks: len(peaks) = len(ref_seq) + 1, one segment per
    reference base. We extract the k-mer centered at each position using
    center_idx.
    """
    n_segments = len(peaks) - 1
    n_bases = len(ref_seq) if ref_seq else 0
    n_usable = min(n_segments, n_bases)

    if n_usable < 10:
        return None

    observed_means = []
    expected_levels = []

    for i in range(n_usable):
        start = int(peaks[i])
        end = int(peaks[i + 1])

        if start >= end or start < 0 or end > len(signal) or end - start < 2:
            continue

        # k-mer extraction: the base at position i is at center_idx within the k-mer
        k_start = i - center_idx
        k_end = k_start + kmer_size
        if k_start < 0 or k_end > n_bases:
            continue

        kmer = ref_seq[k_start:k_end]
        if 'N' in kmer or kmer not in kmer_levels:
            continue

        seg_mean = float(np.mean(signal[start:end]))
        observed_means.append(seg_mean)
        expected_levels.append(kmer_levels[kmer])

    if len(observed_means) < 10:
        return None

    observed = np.array(observed_means, dtype=np.float64)
    expected = np.array(expected_levels, dtype=np.float64)

    obs_std = np.std(observed)
    exp_std = np.std(expected)
    if obs_std < 1e-10 or exp_std < 1e-10:
        return None

    obs_z = (observed - np.mean(observed)) / obs_std
    exp_z = (expected - np.mean(expected)) / exp_std

    r, _ = stats.pearsonr(obs_z, exp_z)
    mean_l1 = float(np.mean(np.abs(obs_z - exp_z)))

    return (len(observed_means), r, mean_l1)


def auto_detect_center_idx(kmer_size, sample_reads):
    """Auto-detect center_idx by trying all positions on sample reads.

    sample_reads: list of (signal, peaks, ref_seq, kmer_levels) tuples.
    Returns the center_idx that maximizes mean Pearson r.
    """
    best_center = kmer_size // 2
    best_r = -2.0

    for candidate in range(kmer_size):
        rs = []
        for signal, peaks, ref_seq, kmer_levels in sample_reads:
            result = evaluate_read(signal, peaks, ref_seq, kmer_levels, kmer_size, candidate)
            if result is not None:
                rs.append(result[1])
        if rs:
            mean_r = np.mean(rs)
            if mean_r > best_r:
                best_r = mean_r
                best_center = candidate

    return best_center, best_r


def main():
    parser = argparse.ArgumentParser(
        description='Evaluate segmentation quality via signal-level concordance.')
    parser.add_argument('--pod5', required=True,
                        help='Path to pod5 file or directory of pod5 files')
    parser.add_argument('--bam', required=True,
                        help='Path to aligned BAM (for reference k-mer context)')
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--peaks',
                       help='Peaks file (rawhash2 --peaks-file format)')
    group.add_argument('--moves',
                       help='Moves TSV file (rawhash2 --moves-file format)')
    parser.add_argument('--level-table', required=True,
                        help='Path to k-mer level table (pore model)')
    parser.add_argument('--output', required=True,
                        help='Output per-read metrics TSV')
    parser.add_argument('--min-mapq', type=int, default=0,
                        help='Minimum mapping quality filter (default: 0)')
    parser.add_argument('--center-idx', type=int, default=None,
                        help='K-mer center index (0-based position of the '
                             '"current" base within the k-mer). If not set, '
                             'auto-detected from the first 50 reads.')
    args = parser.parse_args()

    # Load k-mer level table
    print(f"Loading level table: {args.level_table}", file=sys.stderr)
    kmer_levels = load_level_table(args.level_table)
    kmer_size = len(next(iter(kmer_levels)))
    print(f"  {len(kmer_levels)} k-mers loaded (k={kmer_size})", file=sys.stderr)

    # Load segmentation borders
    if args.peaks:
        print(f"Loading peaks file: {args.peaks}", file=sys.stderr)
        seg_borders = load_peaks_file(args.peaks)
    else:
        print(f"Loading moves file: {args.moves}", file=sys.stderr)
        seg_borders = load_moves_file(args.moves)
    print(f"  {len(seg_borders)} reads loaded", file=sys.stderr)

    # Load pod5 readers
    print(f"Loading pod5 readers: {args.pod5}", file=sys.stderr)
    read_reader_map = get_pod5_readers(args.pod5)
    print(f"  {len(read_reader_map)} reads in pod5", file=sys.stderr)

    # Open BAM
    print(f"Opening BAM: {args.bam}", file=sys.stderr)
    bam_fh = pysam.AlignmentFile(args.bam, 'rb', check_sq=False)

    # First pass: collect sample reads for center_idx auto-detection
    center_idx = args.center_idx
    if center_idx is None:
        print(f"Auto-detecting center_idx (trying all {kmer_size} positions)...",
              file=sys.stderr)
        sample_reads = []
        for bam_read in bam_fh:
            if bam_read.is_supplementary or bam_read.is_secondary or bam_read.is_unmapped:
                continue
            read_id = bam_read.query_name
            if read_id not in seg_borders or read_id not in read_reader_map:
                continue
            try:
                pod5_reader = read_reader_map[read_id]
                pod5_read = next(pod5_reader.reads(selection=[read_id]))
                signal = pod5_read.signal.astype(np.float64)
                peaks = seg_borders[read_id]
                ref_seq, _ = get_ref_seq_from_bam(bam_read)
                if ref_seq is not None:
                    sample_reads.append((signal, peaks, ref_seq, kmer_levels))
            except Exception:
                continue
            if len(sample_reads) >= 50:
                break

        center_idx, best_r = auto_detect_center_idx(kmer_size, sample_reads)
        print(f"  Detected center_idx={center_idx} (mean r={best_r:.4f} on "
              f"{len(sample_reads)} sample reads)", file=sys.stderr)

        # Re-open BAM for the main pass
        bam_fh.close()
        bam_fh = pysam.AlignmentFile(args.bam, 'rb', check_sq=False)
    else:
        print(f"Using center_idx={center_idx}", file=sys.stderr)

    # Main pass
    n_total = 0
    n_evaluated = 0
    n_skipped = 0
    all_pearson = []
    all_l1 = []

    with open(args.output, 'w') as out_fh:
        out_fh.write("read_id\tn_events\tpearson_r\tmean_l1\tmapq\talign_len\tsignal_len\n")

        for bam_read in tqdm(bam_fh, desc="Evaluating", file=sys.stderr):
            n_total += 1

            if bam_read.is_supplementary or bam_read.is_secondary or bam_read.is_unmapped:
                n_skipped += 1
                continue

            if bam_read.mapping_quality < args.min_mapq:
                n_skipped += 1
                continue

            read_id = bam_read.query_name

            if read_id not in seg_borders:
                n_skipped += 1
                continue

            if read_id not in read_reader_map:
                n_skipped += 1
                continue

            try:
                pod5_reader = read_reader_map[read_id]
                pod5_read = next(pod5_reader.reads(selection=[read_id]))
                signal = pod5_read.signal.astype(np.float64)

                peaks = seg_borders[read_id]

                ref_seq, _ = get_ref_seq_from_bam(bam_read)
                if ref_seq is None:
                    n_skipped += 1
                    continue

                result = evaluate_read(
                    signal, peaks, ref_seq, kmer_levels, kmer_size, center_idx)
                if result is None:
                    n_skipped += 1
                    continue

                n_events, pearson_r, mean_l1 = result
                mapq = bam_read.mapping_quality
                align_len = bam_read.query_alignment_length or 0
                signal_len = len(signal)

                out_fh.write(f"{read_id}\t{n_events}\t{pearson_r:.6f}\t"
                             f"{mean_l1:.6f}\t{mapq}\t{align_len}\t{signal_len}\n")

                all_pearson.append(pearson_r)
                all_l1.append(mean_l1)
                n_evaluated += 1

            except Exception as e:
                n_skipped += 1
                if n_skipped <= 5:
                    print(f"  Warning: skipped {read_id}: {e}", file=sys.stderr)
                continue

    # Summary statistics
    print(f"\n=== Evaluation Summary ===", file=sys.stderr)
    print(f"Total reads in BAM: {n_total}", file=sys.stderr)
    print(f"Evaluated: {n_evaluated}", file=sys.stderr)
    print(f"Skipped: {n_skipped}", file=sys.stderr)
    print(f"center_idx: {center_idx}", file=sys.stderr)
    if n_evaluated > 0:
        pearson_arr = np.array(all_pearson)
        l1_arr = np.array(all_l1)
        print(f"Pearson r:  mean={np.mean(pearson_arr):.4f}  "
              f"median={np.median(pearson_arr):.4f}  "
              f"std={np.std(pearson_arr):.4f}", file=sys.stderr)
        print(f"Mean L1:    mean={np.mean(l1_arr):.4f}  "
              f"median={np.median(l1_arr):.4f}  "
              f"std={np.std(l1_arr):.4f}", file=sys.stderr)
    print(f"Output: {args.output}", file=sys.stderr)


if __name__ == '__main__':
    main()
