#!/usr/bin/env bash
# 1_fast5_to_pod5.sh — Convert a directory of FAST5 files to POD5 format.
#
# Uses the `pod5 convert fast5 --output-one-to-one` command to mirror the
# fast5 directory structure in the output, producing one POD5 file per FAST5
# file. The converted output is placed in a directory called pod5_files next
# to the fast5 directory by default.
#
# Usage:
#   bash 1_fast5_to_pod5.sh -i FAST5_DIR [-o OUTPUT_DIR] [-t THREADS]
#
# Example — convert all fast5 files in /path/to/fast5_files/:
#   bash 1_fast5_to_pod5.sh -i /path/to/fast5_files
#   # output: /path/to/pod5_files/  (mirrored directory structure)
#
# Example — specify output directory explicitly:
#   bash 1_fast5_to_pod5.sh -i /path/to/fast5_files -o /path/to/my_pod5 -t 8

set -euo pipefail

###############################################################################
# Defaults
###############################################################################
FAST5_DIR=""
OUTPUT_DIR=""
THREADS=4

###############################################################################
# Help
###############################################################################
usage() {
    cat <<EOF
Usage: $(basename "$0") -i FAST5_DIR [-o OUTPUT_DIR] [-t THREADS]

Convert a directory of FAST5 files to POD5 format.

Required:
  -i PATH   Input fast5 directory

Optional:
  -o PATH   Output directory for pod5 files
            (default: <parent_of_fast5_dir>/pod5_files)
  -t INT    Number of threads (default: ${THREADS})
  -h        Show this help

Output:
  <OUTPUT_DIR>/  (mirrors the fast5 directory structure; one .pod5 per .fast5)

Example:
  # Default output: /data/ecoli/pod5_files/ (mirrored structure)
  bash $(basename "$0") -i /data/ecoli/fast5_files

  # Custom output:
  bash $(basename "$0") -i /data/ecoli/fast5_files -o /data/ecoli/pod5_files -t 8

Notes:
  - Requires pod5 (https://github.com/nanoporetech/pod5-file-format)
    Install via: conda install -c conda-forge pod5
  - pod5 must be on your PATH (activate your conda environment first if needed)
EOF
}

###############################################################################
# Tool discovery
###############################################################################
find_pod5() {
    if command -v pod5 &>/dev/null; then
        echo "pod5"
        return 0
    fi
    echo ""
}

###############################################################################
# Argument parsing
###############################################################################
while getopts ":i:o:t:h" opt "$@"; do
    case "${opt}" in
        i) FAST5_DIR="${OPTARG}" ;;
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
if [ -z "${FAST5_DIR}" ]; then
    echo "Error: -i FAST5_DIR is required." >&2
    usage
    exit 1
fi

if [ ! -d "${FAST5_DIR}" ]; then
    echo "Error: FAST5 directory not found: ${FAST5_DIR}" >&2
    exit 1
fi

# Convert to absolute path
FAST5_DIR="$(realpath "${FAST5_DIR}")"

# Default output directory: parent of fast5 dir, named pod5_files
if [ -z "${OUTPUT_DIR}" ]; then
    OUTPUT_DIR="$(dirname "${FAST5_DIR}")/pod5_files"
fi
OUTPUT_DIR="$(realpath -m "${OUTPUT_DIR}")"

# Discover pod5
POD5_BIN="$(find_pod5)"
if [ -z "${POD5_BIN}" ]; then
    echo "Error: 'pod5' not found. Install via: conda install -c conda-forge pod5" >&2
    exit 1
fi

echo "=== fast5 -> pod5 conversion ==="
echo "  fast5 input : ${FAST5_DIR}"
echo "  pod5 output : ${OUTPUT_DIR}"
echo "  threads     : ${THREADS}"
echo "  pod5 binary : ${POD5_BIN}"
echo ""

# Count input files
N_FAST5=$(find "${FAST5_DIR}" -name "*.fast5" 2>/dev/null | wc -l)
if [ "${N_FAST5}" -eq 0 ]; then
    echo "Error: No .fast5 files found in ${FAST5_DIR}" >&2
    exit 1
fi
echo "Found ${N_FAST5} FAST5 file(s)."

###############################################################################
# Run conversion
###############################################################################
mkdir -p "${OUTPUT_DIR}"

echo "Running: ${POD5_BIN} convert fast5 -r --one-to-one ${FAST5_DIR} -t ${THREADS} -o ${OUTPUT_DIR} ${FAST5_DIR}"
echo ""

"${POD5_BIN}" convert fast5 \
    -r \
    --one-to-one "${FAST5_DIR}" \
    -t "${THREADS}" \
    -o "${OUTPUT_DIR}" \
    "${FAST5_DIR}"

echo ""
echo "Done. Output in: ${OUTPUT_DIR}"
find "${OUTPUT_DIR}" -name "*.pod5" 2>/dev/null | head -20 | sed 's/^/  /' || echo "(no .pod5 files found — check pod5 output above)"
