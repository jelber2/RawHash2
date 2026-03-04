#!/usr/bin/env bash
# 7_refine_moves_remora.sh — Refine move tables using Remora signal mapping.
#
# Takes a dorado-aligned BAM (with --emit-moves --reference) and pod5 files,
# refines the signal-to-base mapping using a k-mer level table, and outputs
# moves_refined.tsv (for rawhash2 --moves-file) and reads_refined.bam.
#
# With -r (--ref-mapping), uses reference-anchored refinement to produce
# sample-level peaks (peaks_refined.tsv) for rawhash2 --peaks-file.
#
# Requires the 'remora-env' conda environment (separate from rawhash2-env
# due to numpy 2.x vs 1.26 conflict).
#
# Usage:
#   bash 7_refine_moves_remora.sh -b ALIGNED_BAM -p POD5_DIR -l LEVEL_TABLE -o OUTPUT_DIR [options]
#
# Example — Query-anchored refinement (default):
#   bash 7_refine_moves_remora.sh \
#     -b /data/d9/dorado-1.4.0-small-sup-refined/reads.bam \
#     -p /data/d9/small_pod5_files \
#     -l /path/to/rawhash2/extern/local_kmer_models/uncalled_r1041_model_only_means.txt \
#     -o /data/d9/dorado-1.4.0-small-sup-refined
#
# Example — Reference-anchored refinement (ground truth peaks):
#   bash 7_refine_moves_remora.sh -r -q 20 \
#     -b /data/d9/dorado-1.4.0-small-sup-refined/reads.bam \
#     -p /data/d9/small_pod5_files \
#     -l /path/to/rawhash2/extern/local_kmer_models/uncalled_r1041_model_only_means.txt \
#     -o /data/d9/dorado-1.4.0-small-sup-refined

set -euo pipefail

###############################################################################
# Resolve script directory to find refine_moves_remora.py
###############################################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAWHASH2="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
REFINE_SCRIPT="${RAWHASH2}/test/scripts/refine_moves_remora.py"

###############################################################################
# Defaults
###############################################################################
ALIGNED_BAM=""
POD5_DIR=""
LEVEL_TABLE=""
OUTPUT_DIR=""
CONDA_ENV="remora-env"
REF_MAPPING=false
MIN_MAPQ=0

###############################################################################
# Help
###############################################################################
usage() {
    cat <<EOF
Usage: $(basename "$0") -b ALIGNED_BAM -p POD5_DIR -l LEVEL_TABLE -o OUTPUT_DIR [options]

Refine move tables using Remora signal mapping refinement. Produces
moves_refined.tsv and reads_refined.bam in the output directory.

With -r, uses reference-anchored refinement (ref_to_signal) to produce
sample-level peaks (peaks_refined.tsv) for rawhash2 --peaks-file.

Required:
  -b PATH   Aligned BAM file with move tables (dorado --emit-moves --reference)
  -p PATH   Pod5 file or directory of pod5 files
  -l PATH   K-mer level table for Remora refinement (must be 2-column: kmer<TAB>level_mean)
            R9.4:  \${RAWHASH2}/extern/local_kmer_models/r94_means_only.txt
            R10:   \${RAWHASH2}/extern/local_kmer_models/uncalled_r1041_model_only_means.txt
  -o PATH   Output directory (moves_refined.tsv and reads_refined.bam go here)

Optional:
  -r        Enable reference-anchored refinement (--ref-mapping).
            Produces peaks_refined.tsv in addition to moves_refined.tsv.
  -q INT    Minimum mapping quality filter (default: ${MIN_MAPQ})
  -c STR    Conda environment name (default: ${CONDA_ENV})
  -h        Show this help

Output files in OUTPUT_DIR:
  moves_refined.tsv    Refined move table for rawhash2 --moves-file
  peaks_refined.tsv    Sample-level peaks for rawhash2 --peaks-file (with -r)
  reads_refined.bam    BAM with refined mv/ts tags
  refine.time          /usr/bin/time -v timing file

Prerequisites:
  - 'remora-env' conda environment with: ont-remora>=3.3.0, pod5, pysam, tqdm
  - Input BAM must be aligned (dorado basecaller --emit-moves --reference ...)
  - Pod5 files must contain the same reads as the BAM

Example (query-anchored, default):
  bash $(basename "\$0") \\
    -b /data/d9/dorado-1.4.0-small-sup-refined/reads.bam \\
    -p /data/d9/small_pod5_files \\
    -l /path/to/rawhash2/extern/local_kmer_models/uncalled_r1041_model_only_means.txt \\
    -o /data/d9/dorado-1.4.0-small-sup-refined

Example (reference-anchored, ground truth peaks):
  bash $(basename "\$0") -r -q 20 \\
    -b /data/d9/dorado-1.4.0-small-sup-refined/reads.bam \\
    -p /data/d9/small_pod5_files \\
    -l /path/to/rawhash2/extern/local_kmer_models/uncalled_r1041_model_only_means.txt \\
    -o /data/d9/dorado-1.4.0-small-sup-refined
EOF
}

###############################################################################
# Argument parsing
###############################################################################
while getopts ":b:p:l:o:c:q:rh" opt; do
    case "${opt}" in
        b) ALIGNED_BAM="${OPTARG}" ;;
        p) POD5_DIR="${OPTARG}" ;;
        l) LEVEL_TABLE="${OPTARG}" ;;
        o) OUTPUT_DIR="${OPTARG}" ;;
        c) CONDA_ENV="${OPTARG}" ;;
        r) REF_MAPPING=true ;;
        q) MIN_MAPQ="${OPTARG}" ;;
        h) usage; exit 0 ;;
        :) echo "Error: Option -${OPTARG} requires an argument." >&2; usage; exit 1 ;;
        \?) echo "Error: Unknown option -${OPTARG}." >&2; usage; exit 1 ;;
    esac
done

###############################################################################
# Validation
###############################################################################
errors=0
[ -z "${ALIGNED_BAM}" ]  && echo "Error: -b ALIGNED_BAM is required." >&2 && errors=$((errors+1))
[ -z "${POD5_DIR}" ]      && echo "Error: -p POD5_DIR is required." >&2 && errors=$((errors+1))
[ -z "${LEVEL_TABLE}" ]   && echo "Error: -l LEVEL_TABLE is required." >&2 && errors=$((errors+1))
[ -z "${OUTPUT_DIR}" ]    && echo "Error: -o OUTPUT_DIR is required." >&2 && errors=$((errors+1))
[ "${errors}" -gt 0 ] && usage && exit 1

[ ! -f "${ALIGNED_BAM}" ]  && echo "Error: Aligned BAM not found: ${ALIGNED_BAM}" >&2 && exit 1
[ ! -e "${POD5_DIR}" ]     && echo "Error: Pod5 path not found: ${POD5_DIR}" >&2 && exit 1
[ ! -f "${LEVEL_TABLE}" ]  && echo "Error: Level table not found: ${LEVEL_TABLE}" >&2 && exit 1
[ ! -f "${REFINE_SCRIPT}" ] && echo "Error: refine_moves_remora.py not found: ${REFINE_SCRIPT}" >&2 && exit 1

ALIGNED_BAM="$(realpath "${ALIGNED_BAM}")"
POD5_DIR="$(realpath "${POD5_DIR}")"
LEVEL_TABLE="$(realpath "${LEVEL_TABLE}")"
OUTPUT_DIR="$(realpath -m "${OUTPUT_DIR}")"

###############################################################################
# Activate conda environment
###############################################################################
echo "=== Remora move table refinement ==="
echo "  aligned BAM   : ${ALIGNED_BAM}"
echo "  pod5 dir      : ${POD5_DIR}"
echo "  level table   : ${LEVEL_TABLE}"
echo "  output dir    : ${OUTPUT_DIR}"
echo "  conda env     : ${CONDA_ENV}"
echo "  ref_mapping   : ${REF_MAPPING}"
echo "  min_mapq      : ${MIN_MAPQ}"
echo "  refine script : ${REFINE_SCRIPT}"
echo ""

source "$(conda info --base)/etc/profile.d/conda.sh"
conda activate "${CONDA_ENV}"

echo "Python: $(which python)"
echo "Remora: $(python -c 'import remora; print(remora.__version__)' 2>/dev/null || echo 'not found')"
echo ""

mkdir -p "${OUTPUT_DIR}"

MOVES_OUT="${OUTPUT_DIR}/moves_refined.tsv"
PEAKS_OUT="${OUTPUT_DIR}/peaks_refined.tsv"
BAM_OUT="${OUTPUT_DIR}/reads_refined.bam"
TIME_FILE="${OUTPUT_DIR}/refine.time"

###############################################################################
# Build python command with optional flags
###############################################################################
PYTHON_ARGS=(
    --pod5 "${POD5_DIR}"
    --bam "${ALIGNED_BAM}"
    --level-table "${LEVEL_TABLE}"
    --output "${MOVES_OUT}"
    --output-bam "${BAM_OUT}"
)

if [ "${REF_MAPPING}" = true ]; then
    PYTHON_ARGS+=(--ref-mapping --output-peaks "${PEAKS_OUT}")
fi

if [ "${MIN_MAPQ}" -gt 0 ]; then
    PYTHON_ARGS+=(--min-mapq "${MIN_MAPQ}")
fi

###############################################################################
# Run refinement
###############################################################################
echo "Running Remora refinement..."
/usr/bin/time -vpo "${TIME_FILE}" \
    python "${REFINE_SCRIPT}" "${PYTHON_ARGS[@]}"

echo ""
echo "Refinement complete."
echo ""

###############################################################################
# Summary stats
###############################################################################
echo "=== Output files ==="
ls -lh "${MOVES_OUT}" "${BAM_OUT}" "${TIME_FILE}" 2>/dev/null
if [ "${REF_MAPPING}" = true ] && [ -f "${PEAKS_OUT}" ]; then
    ls -lh "${PEAKS_OUT}"
fi
echo ""

REFINED_COUNT=$(wc -l < "${MOVES_OUT}")
echo "Reads refined: ${REFINED_COUNT}"

if [ "${REF_MAPPING}" = true ] && [ -f "${PEAKS_OUT}" ]; then
    PEAKS_COUNT=$(wc -l < "${PEAKS_OUT}")
    echo "Peaks file reads: ${PEAKS_COUNT}"
fi

# Report skipped reads (from BAM total vs refined count)
if command -v samtools &>/dev/null; then
    TOTAL_COUNT=$(samtools view -c "${ALIGNED_BAM}")
    SKIPPED=$((TOTAL_COUNT - REFINED_COUNT))
    echo "Total reads in BAM: ${TOTAL_COUNT}"
    echo "Reads skipped: ${SKIPPED}"
fi
echo ""

echo "Timing summary:"
grep -E "Elapsed|Maximum resident" "${TIME_FILE}" 2>/dev/null | sed 's/^\t/  /' || true
echo ""

echo "=== Done ==="
