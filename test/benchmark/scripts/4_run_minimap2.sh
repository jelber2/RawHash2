#!/usr/bin/env bash
# 4_run_minimap2.sh — Map basecalled reads to a reference using minimap2.
#
# Generates the ground-truth PAF file (true_mappings.paf) by aligning
# basecalled FASTA reads to a reference genome in ONT mode (-x map-ont).
# This file is used as the reference for evaluating RawHash2 accuracy in
# scripts 5 and 6.
#
# Usage:
#   bash 4_run_minimap2.sh -i READS_FASTA -r REF_FA -o OUTPUT_DIR [-t THREADS]
#
# Example:
#   bash 4_run_minimap2.sh \
#     -i /data/ecoli/reads.fasta \
#     -r /data/ecoli/ref.fa \
#     -o /data/ecoli/minimap2_baseline \
#     -t 8

set -euo pipefail

###############################################################################
# Defaults
###############################################################################
READS=""
REF=""
OUTPUT_DIR=""
THREADS=4

###############################################################################
# Help
###############################################################################
usage() {
    cat <<EOF
Usage: $(basename "$0") -i READS_FASTA -r REF_FA -o OUTPUT_DIR [-t THREADS]

Map basecalled reads to a reference genome using minimap2 (ONT mode).
Produces the ground-truth PAF used as input for scripts 5 and 6.

Required:
  -i PATH   Input reads FASTA file (from script 3 / dorado basecalling)
  -r PATH   Reference genome FASTA file
  -o PATH   Output directory (will be created if it does not exist)

Optional:
  -t INT    Number of threads (default: ${THREADS})
  -h        Show this help

Output files in OUTPUT_DIR:
  true_mappings.paf   minimap2 ground-truth mappings (PAF format)
  minimap2.time       /usr/bin/time -v timing file

Example:
  bash $(basename "$0") \\
    -i /data/ecoli/reads.fasta \\
    -r /data/ecoli/ref.fa \\
    -o /data/ecoli/minimap2 \\
    -t 8

Notes:
  - minimap2 must be on your PATH (activate your conda environment first if needed)
  - The true_mappings.paf output is used with -g in scripts 5 and 6
EOF
}

###############################################################################
# Tool discovery
###############################################################################
find_tool() {
    local tool="$1"
    if command -v "${tool}" &>/dev/null; then
        echo "${tool}"
        return 0
    fi
    echo ""
}

###############################################################################
# Argument parsing
###############################################################################
while getopts ":i:r:o:t:h" opt "$@"; do
    case "${opt}" in
        i) READS="${OPTARG}" ;;
        r) REF="${OPTARG}" ;;
        o) OUTPUT_DIR="${OPTARG}" ;;
        t) THREADS="${OPTARG}" ;;
        h) usage; exit 0 ;;
        :) echo "Error: Option -${OPTARG} requires an argument." >&2; usage; exit 1 ;;
        \?) echo "Error: Unknown option -${OPTARG}." >&2; usage; exit 1 ;;
    esac
done

###############################################################################
# Validation
###############################################################################
errors=0
[ -z "${READS}" ]      && echo "Error: -i READS_FASTA is required." >&2 && errors=$((errors+1))
[ -z "${REF}" ]        && echo "Error: -r REF_FA is required." >&2 && errors=$((errors+1))
[ -z "${OUTPUT_DIR}" ] && echo "Error: -o OUTPUT_DIR is required." >&2 && errors=$((errors+1))
[ "${errors}" -gt 0 ] && usage && exit 1

[ ! -f "${READS}" ] && echo "Error: Reads file not found: ${READS}" >&2 && exit 1
[ ! -f "${REF}" ]   && echo "Error: Reference file not found: ${REF}" >&2 && exit 1

READS="$(realpath "${READS}")"
REF="$(realpath "${REF}")"
OUTPUT_DIR="$(realpath -m "${OUTPUT_DIR}")"

MM2_BIN="$(find_tool minimap2)"
if [ -z "${MM2_BIN}" ]; then
    echo "Error: 'minimap2' not found in PATH." >&2
    echo "  Install: conda install -c bioconda minimap2  (then activate your environment)" >&2
    exit 1
fi

mkdir -p "${OUTPUT_DIR}"

PAF="${OUTPUT_DIR}/true_mappings.paf"
TIME_FILE="${OUTPUT_DIR}/minimap2.time"

echo "=== minimap2 ground-truth mapping ==="
echo "  reads     : ${READS}"
echo "  reference : ${REF}"
echo "  output    : ${PAF}"
echo "  threads   : ${THREADS}"
echo "  minimap2  : ${MM2_BIN}"
echo ""

###############################################################################
# Run minimap2
###############################################################################
/usr/bin/time -vpo "${TIME_FILE}" \
    "${MM2_BIN}" -x map-ont -t "${THREADS}" -o "${PAF}" "${REF}" "${READS}" \
    2> "${OUTPUT_DIR}/minimap2.err"

echo ""
echo "Done."
echo ""
echo "=== Output files ==="
ls -lh "${PAF}" "${TIME_FILE}" 2>/dev/null
echo ""
echo "Timing summary:"
grep -E "Elapsed|Maximum resident" "${TIME_FILE}" 2>/dev/null | sed 's/^\t/  /' || true
echo ""
echo "Mapped reads: $(grep -v '^$' "${PAF}" 2>/dev/null | wc -l) lines in PAF"
echo "Use ${PAF} as input to -g in scripts 5 or 6."
