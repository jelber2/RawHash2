#!/usr/bin/env bash
# 3_run_dorado.sh — Run Dorado basecaller on a POD5 directory.
#
# Produces a BAM file (reads.bam), a FASTA file (reads.fasta), and a timing
# file (basecall.time). By default runs in GPU auto-detect mode; use -x cpu
# to force CPU mode. The --emit-moves flag is included by default (required
# for using the rawhash2 --moves-file feature).
#
# After basecalling, samtools converts reads.bam -> reads.fasta.
#
# Usage:
#   bash 3_run_dorado.sh -b DORADO_BIN -m MODEL -i POD5_DIR -o OUTPUT_DIR [options]
#
# Example — GPU basecalling with dorado 1.4.0, hac model (R10.4.1):
#   bash 3_run_dorado.sh \
#     -b /path/to/dorado-1.4.0-linux-x64/bin/dorado \
#     -m hac \
#     -i /data/ecoli/small_pod5_files \
#     -o /data/ecoli/dorado
#
# Example — GPU basecalling with explicit R9.4.1 model (dorado 0.9.2):
#   bash 3_run_dorado.sh \
#     -b /path/to/dorado-0.9.2-linux-x64/bin/dorado \
#     -m dna_r9.4.1_e8_hac@v3.3 \
#     -i /data/ecoli/small_pod5_files \
#     -o /data/ecoli/dorado
#
# Example — CPU basecalling (slower, no GPU needed):
#   bash 3_run_dorado.sh \
#     -b /path/to/dorado-1.4.0-linux-x64/bin/dorado \
#     -m hac \
#     -i /data/ecoli/small_pod5_files \
#     -o /data/ecoli/dorado_cpu \
#     -x cpu

set -euo pipefail

###############################################################################
# Defaults
###############################################################################
DORADO_BIN=""
MODEL=""
INPUT_DIR=""
OUTPUT_DIR=""
DEVICE="auto"
THREADS=16
EMIT_MOVES=true
SAMTOOLS_BIN=""

###############################################################################
# Help
###############################################################################
usage() {
    cat <<EOF
Usage: $(basename "$0") -b DORADO_BIN -m MODEL -i POD5_DIR -o OUTPUT_DIR [options]

Run Dorado basecaller on a POD5 directory and produce BAM + FASTA output.

Required:
  -b PATH   Path to dorado binary
            (e.g. /path/to/dorado-1.4.0-linux-x64/bin/dorado)
  -m STR    Model name/preset or path to model directory
            Presets: fast, hac, sup
            R9.4.1 example: dna_r9.4.1_e8_hac@v3.3
            R10.4.1 example: hac  (dorado auto-selects from chemistry)
  -i PATH   Input pod5 directory
  -o PATH   Output directory (will be created if it does not exist)

Optional:
  -x STR    Device to use: auto | cpu | cuda:0 | cuda:all
            (default: auto — dorado auto-detects GPU; strongly prefer GPU)
  -t INT    CPU threads for dorado (default: ${THREADS})
  --no-moves  Do NOT add --emit-moves flag
              (default: --emit-moves is included; needed for rawhash2 --moves-file)
  -s PATH   Path to samtools binary
            (default: searches PATH)
  -h        Show this help

Output files in OUTPUT_DIR:
  reads.bam      Dorado BAM output (with move table if --emit-moves)
  reads.fasta    FASTA reads extracted from BAM via samtools
  basecall.time  /usr/bin/time -v timing file for the dorado run

Device notes:
  auto      dorado picks the best available device (GPU if present, else CPU)
  cpu       Force CPU mode (slow; useful if no GPU available or for testing)
  cuda:0    Use first GPU only
  cuda:all  Use all available GPUs

Dorado versions:
  R10.4.1 chemistry: /path/to/dorado-1.4.0-linux-x64/bin/dorado
  R9.4.1  chemistry: /path/to/dorado-0.9.2-linux-x64/bin/dorado
                     (use with model: dna_r9.4.1_e8_hac@v3.3)

Example:
  # GPU basecalling, R10.4.1 (auto device):
  bash $(basename "$0") \\
    -b /path/to/dorado-1.4.0-linux-x64/bin/dorado \\
    -m hac \\
    -i /path/to/small_pod5_files \\
    -o /path/to/dorado_out

  # CPU basecalling:
  bash $(basename "$0") \\
    -b /path/to/dorado-1.4.0-linux-x64/bin/dorado \\
    -m hac \\
    -i /path/to/small_pod5_files \\
    -o /path/to/dorado_cpu_out \\
    -x cpu
EOF
}

###############################################################################
# Argument parsing — handle --no-moves before getopts (long option)
###############################################################################
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --no-moves) EMIT_MOVES=false; shift ;;
        *) ARGS+=("$1"); shift ;;
    esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

while getopts ":b:m:i:o:x:t:s:h" opt "$@"; do
    case "${opt}" in
        b) DORADO_BIN="${OPTARG}" ;;
        m) MODEL="${OPTARG}" ;;
        i) INPUT_DIR="${OPTARG}" ;;
        o) OUTPUT_DIR="${OPTARG}" ;;
        x) DEVICE="${OPTARG}" ;;
        t) THREADS="${OPTARG}" ;;
        s) SAMTOOLS_BIN="${OPTARG}" ;;
        h) usage; exit 0 ;;
        :) echo "Error: Option -${OPTARG} requires an argument." >&2; usage; exit 1 ;;
        \?) echo "Error: Unknown option -${OPTARG}." >&2; usage; exit 1 ;;
    esac
done

###############################################################################
# Validation
###############################################################################
errors=0
[ -z "${DORADO_BIN}" ]  && echo "Error: -b DORADO_BIN is required." >&2 && errors=$((errors+1))
[ -z "${MODEL}" ]       && echo "Error: -m MODEL is required." >&2 && errors=$((errors+1))
[ -z "${INPUT_DIR}" ]   && echo "Error: -i POD5_DIR is required." >&2 && errors=$((errors+1))
[ -z "${OUTPUT_DIR}" ]  && echo "Error: -o OUTPUT_DIR is required." >&2 && errors=$((errors+1))
[ "${errors}" -gt 0 ] && usage && exit 1

[ ! -f "${DORADO_BIN}" ] && echo "Error: dorado binary not found: ${DORADO_BIN}" >&2 && exit 1
[ ! -d "${INPUT_DIR}" ]  && echo "Error: Input directory not found: ${INPUT_DIR}" >&2 && exit 1

INPUT_DIR="$(realpath "${INPUT_DIR}")"
OUTPUT_DIR="$(realpath -m "${OUTPUT_DIR}")"

if [ -z "${SAMTOOLS_BIN}" ]; then
    if command -v samtools &>/dev/null; then
        SAMTOOLS_BIN="samtools"
    fi
fi
if [ -z "${SAMTOOLS_BIN}" ]; then
    echo "Error: 'samtools' not found." >&2
    echo "  Install: conda install -c bioconda samtools  (activate your environment first)" >&2
    exit 1
fi

###############################################################################
# Build dorado command
###############################################################################
# Device flag: omit for 'auto'; add -x for everything else
DEVICE_FLAG=""
if [ "${DEVICE}" != "auto" ]; then
    DEVICE_FLAG="-x ${DEVICE}"
fi

MOVES_FLAG=""
if [ "${EMIT_MOVES}" = "true" ]; then
    MOVES_FLAG="--emit-moves"
fi

mkdir -p "${OUTPUT_DIR}"

BAM="${OUTPUT_DIR}/reads.bam"
FASTA="${OUTPUT_DIR}/reads.fasta"
TIME_FILE="${OUTPUT_DIR}/basecall.time"

echo "=== Dorado basecalling ==="
echo "  dorado binary : ${DORADO_BIN}"
echo "  model         : ${MODEL}"
echo "  input pod5    : ${INPUT_DIR}"
echo "  output dir    : ${OUTPUT_DIR}"
echo "  device        : ${DEVICE}"
echo "  threads       : ${THREADS}"
echo "  emit-moves    : ${EMIT_MOVES}"
echo "  samtools      : ${SAMTOOLS_BIN}"
echo ""

# Show dorado version
DORADO_VERSION="$("${DORADO_BIN}" --version 2>&1 || true)"
echo "Dorado version: ${DORADO_VERSION}"
echo ""

###############################################################################
# Run basecalling
###############################################################################
echo "Running dorado basecaller..."
/usr/bin/time -vpo "${TIME_FILE}" \
    "${DORADO_BIN}" basecaller \
        ${DEVICE_FLAG} \
        ${MOVES_FLAG} \
        "${MODEL}" \
        "${INPUT_DIR}" \
    > "${BAM}" \
    2>> "${OUTPUT_DIR}/basecall.err"

echo ""
echo "Basecalling complete."
ls -lh "${BAM}"

###############################################################################
# Convert BAM -> FASTA
###############################################################################
echo ""
echo "Converting BAM to FASTA via samtools..."
"${SAMTOOLS_BIN}" fasta "${BAM}" > "${FASTA}" 2>&1

echo "Done."
echo ""
echo "=== Output files ==="
ls -lh "${BAM}" "${FASTA}" "${TIME_FILE}" 2>/dev/null
echo ""
echo "Timing summary:"
grep -E "Elapsed|Maximum resident" "${TIME_FILE}" 2>/dev/null | sed 's/^\t/  /' || true
echo ""
echo "Basecalling log:"
tail -5 "${OUTPUT_DIR}/basecall.err" | sed 's/^/  /' || true
