#!/usr/bin/env bash
# 3_run_dorado.sh — Run Dorado basecaller on a POD5 directory.
#
# Produces a BAM file (reads.bam), a FASTA file (reads.fasta), and a timing
# file (basecall.time). By default runs in GPU auto-detect mode; use -x cpu
# to force CPU mode. The --emit-moves flag is included by default (required
# for using the rawhash2 --moves-file feature).
#
# With -r (--reference), produces a reference-aligned BAM instead of an
# unaligned one. This is required for Remora signal refinement (script 7).
# When -r is used, reads.fasta is extracted from the aligned BAM.
#
# After basecalling, samtools converts reads.bam -> reads.fasta.
#
# Usage:
#   bash 3_run_dorado.sh -b DORADO_BIN -m MODEL -i POD5_DIR -o OUTPUT_DIR [options]
#
# Example — SUP ref-aligned basecalling, R10.4.1 (dorado 1.4.0):
#   bash 3_run_dorado.sh \
#     -b /path/to/dorado-1.4.0-linux-x64/bin/dorado \
#     -m dna_r10.4.1_e8.2_400bps_sup@v5.2.0 \
#     -r /data/ecoli/ref.fa \
#     -i /data/ecoli/small_pod5_files \
#     -o /data/ecoli/dorado-1.4.0-small-sup
#
# Example — SUP ref-aligned basecalling, R9.4.1 (dorado 0.9.2):
#   bash 3_run_dorado.sh \
#     -b /path/to/dorado-0.9.2-linux-x64/bin/dorado \
#     -m dna_r9.4.1_e8_sup@v3.3 \
#     -r /data/ecoli/ref.fa \
#     -i /data/ecoli/small_pod5_files \
#     -o /data/ecoli/dorado-0.9.2-small-sup
#
# Example — HAC basecalling without reference (unaligned BAM):
#   bash 3_run_dorado.sh \
#     -b /path/to/dorado-1.4.0-linux-x64/bin/dorado \
#     -m hac \
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
REFERENCE=""
DEVICE="auto"
THREADS=16
EMIT_MOVES=true
DISABLE_SPLITTING=true
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
            R9.4.1 SUP: dna_r9.4.1_e8_sup@v3.3
            R9.4.1 HAC: dna_r9.4.1_e8_hac@v3.3
            R10.4.1 (dorado 1.4.0): dna_r10.4.1_e8.2_400bps_sup@v5.2.0
            R10.4.1 (dorado 0.9.2): dna_r10.4.1_e8.2_400bps_sup@v4.1.0
  -i PATH   Input pod5 directory
  -o PATH   Output directory (will be created if it does not exist)

Optional:
  -r PATH   Reference FASTA for aligned basecalling (dorado --reference).
            Required for Remora signal refinement (script 7). Produces a
            reference-aligned BAM instead of an unaligned one.
  -x STR    Device to use: auto | cpu | cuda:0 | cuda:all
            (default: auto — dorado auto-detects GPU; strongly prefer GPU)
  -t INT    CPU threads for dorado (default: ${THREADS})
  --no-moves  Do NOT add --emit-moves flag
              (default: --emit-moves is included; needed for rawhash2 --moves-file)
  --enable-read-splitting
              Allow dorado to split reads (default: splitting is disabled via
              --disable-read-splitting so read IDs match pod5 UUIDs)
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

Dorado versions and models:
  R10.4.1 chemistry (dorado 1.4.0): dna_r10.4.1_e8.2_400bps_sup@v5.2.0
  R10.4.1 chemistry (dorado 0.9.2): dna_r10.4.1_e8.2_400bps_sup@v4.1.0
  R9.4.1  chemistry (dorado 0.9.2): dna_r9.4.1_e8_sup@v3.3 (or hac)

Example — SUP ref-aligned basecalling for refinement pipeline:
  bash $(basename "$0") \\
    -b /path/to/dorado-1.4.0-linux-x64/bin/dorado \\
    -m dna_r10.4.1_e8.2_400bps_sup@v5.2.0 \\
    -r /path/to/ref.fa \\
    -i /path/to/small_pod5_files \\
    -o /path/to/dorado-1.4.0-small-sup

Example — HAC basecalling without reference:
  bash $(basename "$0") \\
    -b /path/to/dorado-1.4.0-linux-x64/bin/dorado \\
    -m hac \\
    -i /path/to/small_pod5_files \\
    -o /path/to/dorado_out
EOF
}

###############################################################################
# Argument parsing — handle --no-moves before getopts (long option)
###############################################################################
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --no-moves) EMIT_MOVES=false; shift ;;
        --enable-read-splitting) DISABLE_SPLITTING=false; shift ;;
        *) ARGS+=("$1"); shift ;;
    esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

while getopts ":b:m:i:o:r:x:t:s:h" opt "$@"; do
    case "${opt}" in
        b) DORADO_BIN="${OPTARG}" ;;
        m) MODEL="${OPTARG}" ;;
        i) INPUT_DIR="${OPTARG}" ;;
        o) OUTPUT_DIR="${OPTARG}" ;;
        r) REFERENCE="${OPTARG}" ;;
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
[ -n "${REFERENCE}" ] && [ ! -f "${REFERENCE}" ] && echo "Error: Reference FASTA not found: ${REFERENCE}" >&2 && exit 1

INPUT_DIR="$(realpath "${INPUT_DIR}")"
OUTPUT_DIR="$(realpath -m "${OUTPUT_DIR}")"
[ -n "${REFERENCE}" ] && REFERENCE="$(realpath "${REFERENCE}")"

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

SPLITTING_FLAG=""
if [ "${DISABLE_SPLITTING}" = "true" ]; then
    SPLITTING_FLAG="--disable-read-splitting"
fi

REFERENCE_FLAG=""
if [ -n "${REFERENCE}" ]; then
    REFERENCE_FLAG="--reference ${REFERENCE}"
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
echo "  reference     : ${REFERENCE:-none (unaligned)}"
echo "  device        : ${DEVICE}"
echo "  threads       : ${THREADS}"
echo "  emit-moves    : ${EMIT_MOVES}"
echo "  read-splitting: $([ "${DISABLE_SPLITTING}" = "true" ] && echo "disabled" || echo "enabled")"
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
        ${SPLITTING_FLAG} \
        ${REFERENCE_FLAG} \
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
"${SAMTOOLS_BIN}" fasta "${BAM}" > "${FASTA}"

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
