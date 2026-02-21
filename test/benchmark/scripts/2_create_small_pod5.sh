#!/usr/bin/env bash
# 2_create_small_pod5.sh — Create a small POD5 subset with at most N reads.
#
# Takes the first N read IDs from an existing pod5 directory and writes them
# to a single pod5 file in a new directory. Used to create fast iteration
# datasets from large sequencing runs.
#
# Usage:
#   bash 2_create_small_pod5.sh -i POD5_DIR [-o OUTPUT_DIR] [-n N_READS] [-t THREADS]
#
# Example — first 5000 reads from /path/to/pod5_files:
#   bash 2_create_small_pod5.sh -i /path/to/pod5_files
#   # output: /path/to/small_pod5_files/small.pod5
#
# Example — 2000 reads, custom output:
#   bash 2_create_small_pod5.sh -i /path/to/pod5_files -o /path/to/my_small -n 2000

set -euo pipefail

###############################################################################
# Defaults
###############################################################################
INPUT_DIR=""
OUTPUT_DIR=""
N_READS=5000
THREADS=4

###############################################################################
# Help
###############################################################################
usage() {
    cat <<EOF
Usage: $(basename "$0") -i POD5_DIR [-o OUTPUT_DIR] [-n N_READS] [-t THREADS]

Create a small POD5 subset by taking up to N reads from an existing pod5 directory.
If the input has fewer reads than N, all reads are included.

Required:
  -i PATH   Input pod5 directory (containing *.pod5 files)

Optional:
  -o PATH   Output directory for the small pod5 file
            (default: <parent_of_pod5_dir>/small_pod5_files)
  -n INT    Maximum number of reads to include (default: ${N_READS})
  -t INT    Number of pod5 worker threads (default: ${THREADS})
  -h        Show this help

Output:
  <OUTPUT_DIR>/small.pod5   (single pod5 file with <= N reads)

Example:
  # Default: /data/ecoli/small_pod5_files/small.pod5 with 5000 reads
  bash $(basename "$0") -i /data/ecoli/pod5_files

  # 2000-read subset with custom output:
  bash $(basename "$0") -i /data/ecoli/pod5_files -o /data/ecoli/small -n 2000 -t 8

Notes:
  - Requires pod5 (https://github.com/nanoporetech/pod5-file-format)
  - Reads are selected in the order they appear in the pod5 files
  - Output is a single merged pod5 file called small.pod5
EOF
}

###############################################################################
# Argument parsing
###############################################################################
while getopts ":i:o:n:t:h" opt "$@"; do
    case "${opt}" in
        i) INPUT_DIR="${OPTARG}" ;;
        o) OUTPUT_DIR="${OPTARG}" ;;
        n) N_READS="${OPTARG}" ;;
        t) THREADS="${OPTARG}" ;;
        h) usage; exit 0 ;;
        :) echo "Error: Option -${OPTARG} requires an argument." >&2; usage; exit 1 ;;
        \?) echo "Error: Unknown option -${OPTARG}." >&2; usage; exit 1 ;;
    esac
done

###############################################################################
# Validation
###############################################################################
if [ -z "${INPUT_DIR}" ]; then
    echo "Error: -i POD5_DIR is required." >&2
    usage
    exit 1
fi

if [ ! -d "${INPUT_DIR}" ]; then
    echo "Error: Input directory not found: ${INPUT_DIR}" >&2
    exit 1
fi

INPUT_DIR="$(realpath "${INPUT_DIR}")"

# Default output: sibling of input dir named small_pod5_files
if [ -z "${OUTPUT_DIR}" ]; then
    OUTPUT_DIR="$(dirname "${INPUT_DIR}")/small_pod5_files"
fi
OUTPUT_DIR="$(realpath -m "${OUTPUT_DIR}")"

# Validate N_READS is a positive integer
if ! [[ "${N_READS}" =~ ^[0-9]+$ ]] || [ "${N_READS}" -le 0 ]; then
    echo "Error: -n must be a positive integer (got: ${N_READS})." >&2
    exit 1
fi

# Discover pod5
POD5_BIN=""
if command -v pod5 &>/dev/null; then
    POD5_BIN="pod5"
fi
if [ -z "${POD5_BIN}" ]; then
    echo "Error: 'pod5' not found. Install via: conda install -c conda-forge pod5" >&2
    exit 1
fi

echo "=== Create small POD5 subset ==="
echo "  input pod5 dir   : ${INPUT_DIR}"
echo "  output dir       : ${OUTPUT_DIR}"
echo "  max reads        : ${N_READS}"
echo "  threads          : ${THREADS}"
echo "  pod5 binary      : ${POD5_BIN}"
echo ""

# Check input files exist
N_POD5=$(find "${INPUT_DIR}" -name "*.pod5" 2>/dev/null | wc -l)
if [ "${N_POD5}" -eq 0 ]; then
    echo "Error: No .pod5 files found in ${INPUT_DIR}" >&2
    exit 1
fi
echo "Found ${N_POD5} POD5 file(s) in input directory."

###############################################################################
# Step 1: Get read IDs (process files one at a time to avoid SIGPIPE)
###############################################################################
mkdir -p "${OUTPUT_DIR}"
TEMP_IDS="${OUTPUT_DIR}/read_ids.txt"
trap 'rm -f "${TEMP_IDS}"' EXIT
: > "${TEMP_IDS}"

echo "Extracting up to ${N_READS} read IDs..."
COLLECTED=0
while IFS= read -r pod5_file; do
    [ "${COLLECTED}" -ge "${N_READS}" ] && break
    REMAINING=$(( N_READS - COLLECTED ))
    # -I = only read_id, -H = no header; || true to ignore SIGPIPE from head
    "${POD5_BIN}" view -IH "${pod5_file}" \
        | head -n "${REMAINING}" >> "${TEMP_IDS}" || true
    COLLECTED=$(wc -l < "${TEMP_IDS}")
done < <(find "${INPUT_DIR}" -name "*.pod5" -type f | sort)

ACTUAL_COUNT=$(wc -l < "${TEMP_IDS}")

if [ "${ACTUAL_COUNT}" -eq 0 ]; then
    echo "Error: No read IDs found in ${INPUT_DIR}." >&2
    exit 1
fi

if [ "${ACTUAL_COUNT}" -lt "${N_READS}" ]; then
    echo "Note: Only ${ACTUAL_COUNT} reads available in input (fewer than requested ${N_READS})."
    echo "      Using all ${ACTUAL_COUNT} reads."
else
    echo "Selected ${ACTUAL_COUNT} read IDs."
fi

###############################################################################
# Step 2: Filter to create small pod5
###############################################################################
OUTPUT_FILE="${OUTPUT_DIR}/small.pod5"

echo "Creating ${OUTPUT_FILE} ..."
"${POD5_BIN}" filter \
    -r \
    -t "${THREADS}" \
    --ids "${TEMP_IDS}" \
    --output "${OUTPUT_FILE}" \
    --force-overwrite \
    "${INPUT_DIR}"

echo ""
echo "Done. Created: ${OUTPUT_FILE}"
echo "Read count: ${ACTUAL_COUNT}"
ls -lh "${OUTPUT_FILE}"
