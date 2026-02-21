#!/usr/bin/env bash
# 5_run_rawhash2_baseline.sh — Run RawHash2 and establish a v0 baseline.
#
# Thin wrapper around 6_run_rawhash2_eval.sh that defaults the output prefix
# to "rawhash2_baseline" and prints a baseline-specific header. All arguments
# are forwarded to script 6.
#
# Usage:
#   bash 5_run_rawhash2_baseline.sh \
#     -b RH2_BIN -i POD5_DIR -r REF_FA -p PORE_MODEL -g GT_PAF -o OUTPUT_DIR \
#     [options]
#
# See 6_run_rawhash2_eval.sh -h for the full list of options.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EVAL_SCRIPT="${SCRIPT_DIR}/6_run_rawhash2_eval.sh"

if [ ! -f "${EVAL_SCRIPT}" ]; then
    echo "Error: 6_run_rawhash2_eval.sh not found at ${EVAL_SCRIPT}" >&2
    exit 1
fi

# Default prefix to rawhash2_baseline unless the user already supplied -n
HAS_PREFIX=false
for arg in "$@"; do
    if [ "${arg}" = "-n" ]; then
        HAS_PREFIX=true
        break
    fi
done

if [ "${HAS_PREFIX}" = "false" ]; then
    exec bash "${EVAL_SCRIPT}" -n rawhash2_baseline "$@"
else
    exec bash "${EVAL_SCRIPT}" "$@"
fi
