#!/usr/bin/env bash
# 6_run_rawhash2_eval.sh — Run RawHash2 and compare against any reference PAF.
#
# Iterative evaluation script for testing different RawHash2 parameters.
# Functionally identical to script 5, except the -g (comparison PAF) flag is
# fully flexible: you can supply the minimap2 ground-truth PAF (from script 4),
# a previous RawHash2 baseline PAF (from script 5), or any other PAF.
#
# Common use cases:
#   - Change preset (-x), minimizer window (-e "-w 3"), or other parameters
#   - Compare new parameter run against the original minimap2 ground truth
#   - Compare new parameter run against the v0 baseline rawhash2 PAF to
#     measure the relative change in accuracy/throughput
#
# Usage:
#   bash 6_run_rawhash2_eval.sh \
#     -b RH2_BIN -i POD5_DIR -r REF_FA -p PORE_MODEL -g COMPARISON_PAF \
#     -o OUTPUT_DIR [options]
#
# Example — test minimizer window -w 3 vs minimap2 ground truth:
#   bash 6_run_rawhash2_eval.sh \
#     -b /path/to/rawhash2 \
#     -i /data/ecoli/small_pod5_files \
#     -r /data/ecoli/ref.fa \
#     -p /path/to/pore_model.txt \
#     -g /data/ecoli/minimap2/true_mappings.paf \
#     -o /data/ecoli/eval_w3 \
#     --r10 -e "-w 3" -n rawhash2_w3 -t 8
#
# Example — compare a new run against the v0 baseline rawhash2 PAF:
#   bash 6_run_rawhash2_eval.sh \
#     -b /path/to/rawhash2 \
#     -i /data/ecoli/small_pod5_files \
#     -r /data/ecoli/ref.fa \
#     -p /path/to/pore_model.txt \
#     -g /data/ecoli/v0_baseline/rawhash2_baseline.paf \
#     -o /data/ecoli/eval_w3 \
#     --r10 -e "-w 3" -n rawhash2_w3 -t 8

set -euo pipefail

###############################################################################
# Defaults
###############################################################################
RH2_BIN=""
INPUT_DIR=""
REF=""
PORE=""
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
Usage: $(basename "$0") -b RH2_BIN -i POD5_DIR -r REF_FA -p PORE_MODEL \\
                         -g COMPARISON_PAF -o OUTPUT_DIR [options]

Run RawHash2 (index + map) and compare the output against any reference PAF.
Used for iterative parameter tuning. The -g PAF can be:
  - minimap2 ground-truth PAF (from script 4): standard accuracy evaluation
  - a previous RawHash2 baseline PAF (from script 5): relative change analysis
  - any other PAF in minimap2/PAF format

Required:
  -b PATH   Path to rawhash2 binary
  -i PATH   Input signal directory (pod5 / fast5 / slow5)
  -r PATH   Reference genome FASTA file
  -p PATH   Pore model file
            R9.4.1:  <rawhash2>/extern/kmer_models/legacy/
                     legacy_r9.4_180mv_450bps_6mer/template_median68pA.model
            R10.4.1: <rawhash2>/extern/local_kmer_models/
                     uncalled_r1041_model_only_means.txt
  -g PATH   Comparison PAF file (minimap2, baseline rawhash2, or any PAF)
  -o PATH   Output directory (will be created if it does not exist)

Optional:
  -x STR    RawHash2 preset: sensitive | viral (default: ${PRESET})
  -t INT    Number of threads (default: ${THREADS})
  -n STR    Output file prefix (default: ${PREFIX})
  --r10     Add --r10 flag for R10.4.1 chemistry (default: off for R9.4)
  -e STR    Extra RawHash2 parameters, e.g. "-w 3" (default: none)
  -h        Show this help

Output files in OUTPUT_DIR:
  PREFIX.ind            RawHash2 index
  PREFIX.paf            RawHash2 mapping output (PAF format)
  PREFIX_ann.paf        Annotated PAF with rf:Z:tp/fp/fn/tn/na labels
  PREFIX.throughput     Summary stats: confusion matrix + BP/sec
  PREFIX.comparison     Detailed accuracy metrics (TP/FP/FN/TN, F1, etc.)
  PREFIX_index.time     Timing file for the indexing step
  PREFIX_map.time       Timing file for the mapping step
  PREFIX_index.out/err  stdout/stderr from the indexing step
  PREFIX_map.out/err    stdout/stderr from the mapping step
  PREFIX.results        Combined results file

Comparison PAF notes:
  Using minimap2 true_mappings.paf as -g gives absolute accuracy (TP/FP/FN).
  Using a previous rawhash2 .paf as -g shows how reads classified differently
  between the two runs (relative tp/fp/fn/tn vs the baseline rawhash2 run).

Example — test -w 3 vs minimap2 ground truth:
  bash $(basename "$0") \\
    -b /path/to/rawhash2 \\
    -i /path/to/small_pod5_files \\
    -r /path/to/ref.fa \\
    -p /path/to/uncalled_r1041_model_only_means.txt \\
    -g /path/to/minimap2/true_mappings.paf \\
    -o /path/to/eval_w3 \\
    --r10 -e "-w 3" -n rawhash2_w3 -t 8

Example — compare -w 3 run against v0 baseline rawhash2 PAF:
  bash $(basename "$0") \\
    -b /path/to/rawhash2 \\
    -i /path/to/small_pod5_files \\
    -r /path/to/ref.fa \\
    -p /path/to/uncalled_r1041_model_only_means.txt \\
    -g /path/to/v0_baseline/rawhash2_baseline.paf \\
    -o /path/to/eval_w3_vs_baseline \\
    --r10 -e "-w 3" -n rawhash2_w3_vs_baseline -t 8
EOF
}

###############################################################################
# Argument parsing — handle --r10 long option before getopts
###############################################################################
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --r10) R10_FLAG=true; shift ;;
        *) ARGS+=("$1"); shift ;;
    esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

while getopts ":b:i:r:p:g:o:x:t:n:e:h" opt "$@"; do
    case "${opt}" in
        b) RH2_BIN="${OPTARG}" ;;
        i) INPUT_DIR="${OPTARG}" ;;
        r) REF="${OPTARG}" ;;
        p) PORE="${OPTARG}" ;;
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
[ -z "${REF}" ]        && echo "Error: -r REF_FA is required." >&2     && errors=$((errors+1))
[ -z "${PORE}" ]       && echo "Error: -p PORE_MODEL is required." >&2 && errors=$((errors+1))
[ -z "${COMP_PAF}" ]   && echo "Error: -g COMPARISON_PAF is required." >&2 && errors=$((errors+1))
[ -z "${OUTPUT_DIR}" ] && echo "Error: -o OUTPUT_DIR is required." >&2 && errors=$((errors+1))
[ "${errors}" -gt 0 ] && usage && exit 1

[ ! -f "${RH2_BIN}" ]   && echo "Error: rawhash2 binary not found: ${RH2_BIN}" >&2 && exit 1
[ ! -d "${INPUT_DIR}" ] && echo "Error: Input directory not found: ${INPUT_DIR}" >&2 && exit 1
[ ! -f "${REF}" ]       && echo "Error: Reference not found: ${REF}" >&2 && exit 1
[ ! -f "${PORE}" ]      && echo "Error: Pore model not found: ${PORE}" >&2 && exit 1
[ ! -f "${COMP_PAF}" ]  && echo "Error: Comparison PAF not found: ${COMP_PAF}" >&2 && exit 1

# Verify evaluation scripts exist
PAFSTATS="${TEST_SCRIPTS_DIR}/pafstats.py"
ANALYZE_PAF="${TEST_SCRIPTS_DIR}/analyze_paf.py"
[ ! -f "${PAFSTATS}" ]    && echo "Error: pafstats.py not found at ${PAFSTATS}" >&2 && exit 1
[ ! -f "${ANALYZE_PAF}" ] && echo "Error: analyze_paf.py not found at ${ANALYZE_PAF}" >&2 && exit 1

# Resolve paths
INPUT_DIR="$(realpath "${INPUT_DIR}")"
REF="$(realpath "${REF}")"
PORE="$(realpath "${PORE}")"
COMP_PAF="$(realpath "${COMP_PAF}")"
OUTPUT_DIR="$(realpath -m "${OUTPUT_DIR}")"

# Build R10 flag string
R10_STR=""
[ "${R10_FLAG}" = "true" ] && R10_STR="--r10"

# Combine R10 + extra params
ALL_EXTRA="${R10_STR}${R10_STR:+ }${EXTRA_PARAMS}"

mkdir -p "${OUTPUT_DIR}"

# Output file paths
IND="${OUTPUT_DIR}/${PREFIX}.ind"
PAF="${OUTPUT_DIR}/${PREFIX}.paf"
ANN_PAF="${OUTPUT_DIR}/${PREFIX}_ann.paf"
THROUGHPUT="${OUTPUT_DIR}/${PREFIX}.throughput"
COMPARISON="${OUTPUT_DIR}/${PREFIX}.comparison"
IDX_TIME="${OUTPUT_DIR}/${PREFIX}_index.time"
MAP_TIME="${OUTPUT_DIR}/${PREFIX}_map.time"
IDX_OUT="${OUTPUT_DIR}/${PREFIX}_index.out"
IDX_ERR="${OUTPUT_DIR}/${PREFIX}_index.err"
MAP_OUT="${OUTPUT_DIR}/${PREFIX}_map.out"
MAP_ERR="${OUTPUT_DIR}/${PREFIX}_map.err"
RESULTS="${OUTPUT_DIR}/${PREFIX}.results"

echo "=== RawHash2 Evaluation Run ==="
echo "  rawhash2 binary  : ${RH2_BIN}"
echo "  signals dir      : ${INPUT_DIR}"
echo "  reference        : ${REF}"
echo "  pore model       : ${PORE}"
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
# Step 1: Build index
###############################################################################
echo "--- Step 1/4: Indexing ---"
echo "Command: ${RH2_BIN} -x ${PRESET} -t ${THREADS} -p ${PORE} ${ALL_EXTRA} -d ${IND} ${REF}"
echo ""

/usr/bin/time -vpo "${IDX_TIME}" \
    "${RH2_BIN}" -x "${PRESET}" -t "${THREADS}" \
    -p "${PORE}" \
    -d "${IND}" \
    ${ALL_EXTRA} \
    "${REF}" \
    > "${IDX_OUT}" 2> "${IDX_ERR}"

echo "Indexing done."
grep -E "Elapsed|Maximum resident" "${IDX_TIME}" 2>/dev/null | sed 's/^\t/  /' || true
echo ""

###############################################################################
# Step 2: Map signals
###############################################################################
echo "--- Step 2/4: Mapping ---"
echo "Command: ${RH2_BIN} -x ${PRESET} -t ${THREADS} ${ALL_EXTRA} -o ${PAF} ${IND} ${INPUT_DIR}"
echo ""

/usr/bin/time -vpo "${MAP_TIME}" \
    "${RH2_BIN}" -x "${PRESET}" -t "${THREADS}" \
    -o "${PAF}" \
    ${ALL_EXTRA} \
    "${IND}" \
    "${INPUT_DIR}" \
    > "${MAP_OUT}" 2> "${MAP_ERR}"

echo "Mapping done."
echo "PAF lines: $(wc -l < "${PAF}")"
grep -E "Elapsed|Maximum resident" "${MAP_TIME}" 2>/dev/null | sed 's/^\t/  /' || true
echo ""

###############################################################################
# Step 3: Evaluate accuracy
###############################################################################
echo "--- Step 3/4: Accuracy evaluation (pafstats) ---"
python3 "${PAFSTATS}" "${PAF}" -r "${COMP_PAF}" -a \
    > "${ANN_PAF}" 2> "${THROUGHPUT}"
echo "pafstats done."
cat "${THROUGHPUT}"
echo ""

###############################################################################
# Step 4: Detailed analysis
###############################################################################
echo "--- Step 4/4: Detailed analysis (analyze_paf) ---"
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
    echo "  pore model      : ${PORE}"
    echo "  comparison PAF  : ${COMP_PAF}"
    echo ""
    echo "--- Throughput and Confusion Matrix ---"
    cat "${THROUGHPUT}"
    echo ""
    echo "--- Accuracy Metrics ---"
    cat "${COMPARISON}"
    echo ""
    echo "(Indexing) Timing:"
    cat "${IDX_TIME}"
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
ls -lh "${IND}" "${PAF}" "${ANN_PAF}" "${THROUGHPUT}" "${COMPARISON}" "${RESULTS}" 2>/dev/null | sed 's/^/  /'
