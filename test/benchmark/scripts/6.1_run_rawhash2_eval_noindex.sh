#!/usr/bin/env bash
# 6.1_run_rawhash2_eval_noindex.sh — Map + evaluate using a pre-built index.
#
# Like script 6, but skips the indexing step entirely. Takes a pre-built .ind
# file (or a symlink to one) instead of reference FASTA and pore model.
#
# Use this when:
#   - Your experiment does NOT change indexing parameters (-w, -e, -q, -k,
#     --sig-diff, preset, --r10, pore model)
#   - You want to reuse the v0 baseline index to save time
#   - You are running the same dataset against multiple comparison PAFs
#
# Parameters that DO NOT affect the index (safe to change with this script):
#   Chaining:    --min-anchors, --min-score, --bw, --max-target-gap, etc.
#   Mapping:     --max-chunks, --min-mapq, --disable-adaptive
#   Segmentation: --seg-window-length*, --seg-threshold*, --seg-peak-height, etc.
#   External:    --peaks-file, --events-file, --moves-file
#   Device:      --bp-per-sec, --sample-rate, --chunk-size
#
# Parameters that DO affect the index (use script 6 instead):
#   -x preset, --r10, -p pore model, -k, -e, -q, -w, --sig-diff, --store-sig
#
# Usage:
#   bash 6.1_run_rawhash2_eval_noindex.sh \
#     -b RH2_BIN -i POD5_DIR -I INDEX_FILE -g COMPARISON_PAF \
#     -o OUTPUT_DIR [options]
#
# Example — test --min-anchors 5 reusing v0 index:
#   bash 6.1_run_rawhash2_eval_noindex.sh \
#     -b /path/to/rawhash2 \
#     -i /data/ecoli/small_pod5_files \
#     -I /data/ecoli/v0_baseline/rawhash2_baseline.ind \
#     -g /data/ecoli/minimap2/true_mappings.paf \
#     -o /data/ecoli/eval_min_anchors_5 \
#     -x sensitive --r10 \
#     -e "--min-anchors 5" -n rawhash2_min_anchors_5 -t 16

set -euo pipefail

###############################################################################
# Defaults
###############################################################################
RH2_BIN=""
INPUT_DIR=""
INDEX_FILE=""
COMP_PAF=""
OUTPUT_DIR=""
PRESET="sensitive"
THREADS=4
PREFIX="rawhash2_eval"
R10_FLAG=false
EXTRA_PARAMS=""

###############################################################################
# Script directory — for finding pafstats.py and analyze_paf.py
###############################################################################
BENCHMARK_SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_SCRIPTS_DIR="$(realpath "${BENCHMARK_SCRIPTS_DIR}/../../scripts")"

###############################################################################
# Help
###############################################################################
usage() {
    cat <<EOF
Usage: $(basename "$0") -b RH2_BIN -i POD5_DIR -I INDEX_FILE \\
                         -g COMPARISON_PAF -o OUTPUT_DIR [options]

Map signals using a pre-built RawHash2 index and compare against any PAF.
Skips the indexing step entirely — use this when your experiment only changes
mapping/chaining/segmentation parameters (not indexing parameters).

Required:
  -b PATH   Path to rawhash2 binary
  -i PATH   Input signal directory (pod5 / fast5 / slow5)
  -I PATH   Pre-built RawHash2 index file (.ind)
  -g PATH   Comparison PAF file (minimap2, baseline rawhash2, or any PAF)
  -o PATH   Output directory (will be created if it does not exist)

Optional:
  -x STR    RawHash2 preset (default: ${PRESET})
  -t INT    Number of threads (default: ${THREADS})
  -n STR    Output file prefix (default: ${PREFIX})
  --r10     Add --r10 flag for R10.4.1 chemistry
  -e STR    Extra RawHash2 parameters, e.g. "--min-anchors 5"
  -h        Show this help

Note: -x and --r10 must match the preset/chemistry used to build the index.

Output files in OUTPUT_DIR:
  PREFIX.paf            RawHash2 mapping output (PAF format)
  PREFIX_ann.paf        Annotated PAF with rf:Z:tp/fp/fn/tn/na labels
  PREFIX.throughput     Summary stats: confusion matrix + BP/sec
  PREFIX.comparison     Detailed accuracy metrics (TP/FP/FN/TN, F1, etc.)
  PREFIX_map.time       Timing file for the mapping step
  PREFIX_map.out/err    stdout/stderr from the mapping step
  PREFIX.results        Combined results file

Indexing parameters that require script 6 (full index + map):
  -x preset, --r10, -p pore model, -k, -e (events), -q, -w, --sig-diff

Mapping parameters safe to change with this script (6.1):
  --min-anchors, --min-score, --bw, --max-target-gap, --max-query-gap,
  --best-chains, --chain-gap-scale, --chain-skip-scale, --max-chunks,
  --min-mapq, --disable-adaptive, --seg-window-length*, --seg-threshold*,
  --seg-peak-height, --min-seg-length, --max-seg-length, --bp-per-sec,
  --sample-rate, --chunk-size, --peaks-file, --events-file, --moves-file
EOF
}

###############################################################################
# Argument parsing — handle --r10 and -I before getopts
###############################################################################
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --r10) R10_FLAG=true; shift ;;
        -I)
            if [ $# -lt 2 ]; then
                echo "Error: -I requires an argument." >&2; exit 1
            fi
            INDEX_FILE="$2"; shift 2 ;;
        *) ARGS+=("$1"); shift ;;
    esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

while getopts ":b:i:g:o:x:t:n:e:h" opt "$@"; do
    case "${opt}" in
        b) RH2_BIN="${OPTARG}" ;;
        i) INPUT_DIR="${OPTARG}" ;;
        g) COMP_PAF="${OPTARG}" ;;
        o) OUTPUT_DIR="${OPTARG}" ;;
        x) PRESET="${OPTARG}" ;;
        t) THREADS="${OPTARG}" ;;
        n) PREFIX="${OPTARG}" ;;
        e) EXTRA_PARAMS="${OPTARG}" ;;
        h) usage; exit 0 ;;
        :) echo "Error: Option -${OPTARG} requires an argument." >&2; usage; exit 1 ;;
        \?) echo "Error: Unknown option -${OPTARG}." >&2; usage; exit 1 ;;
    esac
done

###############################################################################
# Validation
###############################################################################
errors=0
[ -z "${RH2_BIN}" ]    && echo "Error: -b RH2_BIN is required." >&2    && errors=$((errors+1))
[ -z "${INPUT_DIR}" ]  && echo "Error: -i POD5_DIR is required." >&2   && errors=$((errors+1))
[ -z "${INDEX_FILE}" ] && echo "Error: -I INDEX_FILE is required." >&2 && errors=$((errors+1))
[ -z "${COMP_PAF}" ]   && echo "Error: -g COMPARISON_PAF is required." >&2 && errors=$((errors+1))
[ -z "${OUTPUT_DIR}" ] && echo "Error: -o OUTPUT_DIR is required." >&2 && errors=$((errors+1))
[ "${errors}" -gt 0 ] && usage && exit 1

[ ! -f "${RH2_BIN}" ]    && echo "Error: rawhash2 binary not found: ${RH2_BIN}" >&2 && exit 1
[ ! -d "${INPUT_DIR}" ]  && echo "Error: Input directory not found: ${INPUT_DIR}" >&2 && exit 1
[ ! -f "${INDEX_FILE}" ] && echo "Error: Index file not found: ${INDEX_FILE}" >&2 && exit 1
[ ! -f "${COMP_PAF}" ]   && echo "Error: Comparison PAF not found: ${COMP_PAF}" >&2 && exit 1

# Verify evaluation scripts exist
PAFSTATS="${TEST_SCRIPTS_DIR}/pafstats.py"
ANALYZE_PAF="${TEST_SCRIPTS_DIR}/analyze_paf.py"
[ ! -f "${PAFSTATS}" ]    && echo "Error: pafstats.py not found at ${PAFSTATS}" >&2 && exit 1
[ ! -f "${ANALYZE_PAF}" ] && echo "Error: analyze_paf.py not found at ${ANALYZE_PAF}" >&2 && exit 1

# Resolve paths
INPUT_DIR="$(realpath "${INPUT_DIR}")"
INDEX_FILE="$(realpath "${INDEX_FILE}")"
COMP_PAF="$(realpath "${COMP_PAF}")"
OUTPUT_DIR="$(realpath -m "${OUTPUT_DIR}")"

# Build R10 flag string
R10_STR=""
[ "${R10_FLAG}" = "true" ] && R10_STR="--r10"

# Combine R10 + extra params
ALL_EXTRA="${R10_STR}${R10_STR:+ }${EXTRA_PARAMS}"

mkdir -p "${OUTPUT_DIR}"

# Output file paths
PAF="${OUTPUT_DIR}/${PREFIX}.paf"
ANN_PAF="${OUTPUT_DIR}/${PREFIX}_ann.paf"
THROUGHPUT="${OUTPUT_DIR}/${PREFIX}.throughput"
COMPARISON="${OUTPUT_DIR}/${PREFIX}.comparison"
MAP_TIME="${OUTPUT_DIR}/${PREFIX}_map.time"
MAP_OUT="${OUTPUT_DIR}/${PREFIX}_map.out"
MAP_ERR="${OUTPUT_DIR}/${PREFIX}_map.err"
RESULTS="${OUTPUT_DIR}/${PREFIX}.results"

echo "=== RawHash2 Evaluation Run (no indexing) ==="
echo "  rawhash2 binary  : ${RH2_BIN}"
echo "  signals dir      : ${INPUT_DIR}"
echo "  index file       : ${INDEX_FILE} ($(du -h "${INDEX_FILE}" | cut -f1))"
echo "  comparison PAF   : ${COMP_PAF}"
echo "  preset           : ${PRESET}"
echo "  threads          : ${THREADS}"
echo "  chemistry        : $([ "${R10_FLAG}" = "true" ] && echo R10.4.1 || echo R9.4.1)"
echo "  extra params     : ${ALL_EXTRA:-(none)}"
echo "  prefix           : ${PREFIX}"
echo "  output dir       : ${OUTPUT_DIR}"
echo ""

# Show rawhash2 version
RH2_VERSION="$("${RH2_BIN}" --version 2>&1 | head -1 || true)"
echo "RawHash2 version: ${RH2_VERSION}"
echo ""

###############################################################################
# Step 1/3: Map signals (using pre-built index)
###############################################################################
echo "--- Step 1/3: Mapping (index: ${INDEX_FILE##*/}) ---"
echo "Command: ${RH2_BIN} -x ${PRESET} -t ${THREADS} ${ALL_EXTRA} -o ${PAF} ${INDEX_FILE} ${INPUT_DIR}"
echo ""

/usr/bin/time -vpo "${MAP_TIME}" \
    "${RH2_BIN}" -x "${PRESET}" -t "${THREADS}" \
    -o "${PAF}" \
    ${ALL_EXTRA} \
    "${INDEX_FILE}" \
    "${INPUT_DIR}" \
    > "${MAP_OUT}" 2> "${MAP_ERR}"

echo "Mapping done."
echo "PAF lines: $(wc -l < "${PAF}")"
grep -E "Elapsed|Maximum resident" "${MAP_TIME}" 2>/dev/null | sed 's/^\t/  /' || true
echo ""

###############################################################################
# Step 2/3: Evaluate accuracy
###############################################################################
echo "--- Step 2/3: Accuracy evaluation (pafstats) ---"
python3 "${PAFSTATS}" "${PAF}" -r "${COMP_PAF}" -a \
    > "${ANN_PAF}" 2> "${THROUGHPUT}"
echo "pafstats done."
cat "${THROUGHPUT}"
echo ""

###############################################################################
# Step 3/3: Detailed analysis
###############################################################################
echo "--- Step 3/3: Detailed analysis (analyze_paf) ---"
python3 "${ANALYZE_PAF}" "${ANN_PAF}" > "${COMPARISON}" 2>&1
echo "analyze_paf done."
cat "${COMPARISON}"
echo ""

###############################################################################
# Combine into .results file
###############################################################################
{
    echo "RawHash2 Evaluation Results — ${PREFIX}"
    echo "$(printf '=%.0s' {1..50})"
    echo ""
    echo "Run parameters:"
    echo "  preset          : ${PRESET}"
    echo "  threads         : ${THREADS}"
    echo "  chemistry       : $([ "${R10_FLAG}" = "true" ] && echo R10.4.1 || echo R9.4.1)"
    echo "  extra params    : ${ALL_EXTRA:-(none)}"
    echo "  index           : ${INDEX_FILE}"
    echo "  comparison PAF  : ${COMP_PAF}"
    echo ""
    echo "--- Throughput and Confusion Matrix ---"
    cat "${THROUGHPUT}"
    echo ""
    echo "--- Accuracy Metrics ---"
    cat "${COMPARISON}"
    echo ""
    echo "(Indexing) Timing:"
    echo "  (skipped — used pre-built index: ${INDEX_FILE})"
    echo ""
    echo "(Mapping) Timing:"
    cat "${MAP_TIME}"
} > "${RESULTS}"

echo "=== Evaluation complete ==="
echo ""
echo "Key results:"
grep -E "precision:|recall:|F-1|BP per sec|Elapsed" "${RESULTS}" 2>/dev/null | head -10 | sed 's/^/  /'
echo ""
echo "Full results saved to: ${RESULTS}"
echo ""
echo "Output files:"
ls -lh "${PAF}" "${ANN_PAF}" "${THROUGHPUT}" "${COMPARISON}" "${RESULTS}" 2>/dev/null | sed 's/^/  /'
