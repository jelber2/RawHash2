#!/bin/bash
#
# Automated test script for RawHash2 live streaming (MinKNOW/Icarust)
#
# This script:
# 1. Builds RawHash2 with gRPC support
# 2. Creates an R10 index from E. coli reference
# 3. Starts Icarust simulator in the background
# 4. Runs RawHash2 in live mode
# 5. Cleans up and reports results
#
# Prerequisites:
#   - Icarust built at $ICARUST_DIR/target/release/icarust
#   - gRPC libraries installed (brew install grpc on macOS, or conda)
#   - Valid TLS certificates in Icarust's static/tls_certs/ (see LIVE.md
#     troubleshooting if Icarust ships with expired certificates)
#
# Usage:
#   bash test_live.sh
#
# Environment variables:
#   ICARUST_DIR    Path to Icarust repo (default: ../../Icarust relative to this script)
#   LIVE_DURATION  Seconds to run (default: 30)
#   CHANNELS       Number of channels to monitor (default: 10)
#
# Results saved to ${TMPDIR:-/tmp}/rawhash2_live_test/

set -e

# Navigate to RawHash2 root
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RAWHASH2_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
cd "$RAWHASH2_ROOT"
echo "[Setup] Working directory: $RAWHASH2_ROOT"

# Configuration
ICARUST_DIR="${ICARUST_DIR:-$(dirname "$RAWHASH2_ROOT")/Icarust}"
LIVE_DURATION="${LIVE_DURATION:-30}"
CHANNELS="${CHANNELS:-10}"
ICARUST_BIN="$ICARUST_DIR/target/release/icarust"
ICARUST_CERTS="$ICARUST_DIR/static/tls_certs"
ICARUST_CA="$ICARUST_CERTS/ca.crt"

# Use TMPDIR if set, otherwise /tmp
WORK_DIR="${TMPDIR:-/tmp}/rawhash2_live_test"
mkdir -p "$WORK_DIR"

# Detect platform and set environment
if [[ "$OSTYPE" == "darwin"* ]]; then
    export HDF5_DIR=$(brew --prefix hdf5@1.10)
    echo "[Platform] macOS detected (HDF5_DIR=$HDF5_DIR)"
else
    # Activate conda environment if available
    if command -v conda &>/dev/null; then
        source $(conda info --base)/etc/profile.d/conda.sh
        # Try common environment names; skip if none found
        conda activate rawhash2-live 2>/dev/null || \
        conda activate rawhash2 2>/dev/null || \
        echo "[Platform] Linux detected (no matching conda env found, using current environment)"
    else
        echo "[Platform] Linux detected"
    fi
fi

# Check Icarust
if [ ! -x "$ICARUST_BIN" ]; then
    echo "[ERROR] Icarust not found at: $ICARUST_BIN"
    echo "        Set ICARUST_DIR to the Icarust repo root."
    exit 1
fi
echo "[Setup] Icarust: $ICARUST_BIN"

# Check TLS certificates
if [ ! -f "$ICARUST_CA" ]; then
    echo "[ERROR] CA certificate not found at: $ICARUST_CA"
    echo "        Check Icarust installation (static/tls_certs/ directory)."
    exit 1
fi

# Warn if certificates are expired
if command -v openssl &>/dev/null; then
    if ! openssl x509 -in "$ICARUST_CERTS/server.crt" -noout -checkend 0 2>/dev/null; then
        echo "[WARN] Icarust TLS certificate appears expired!"
        echo "       See LIVE.md troubleshooting for certificate regeneration instructions."
        echo "       Continuing anyway (may fail at TLS handshake)..."
        echo ""
    fi
fi

# Step 1: Build RawHash2 with gRPC
echo ""
echo "============================================"
echo "[1/4] Building RawHash2 with gRPC support"
echo "============================================"
make cmake CMAKE_OPTS="-DENABLE_GRPC=ON" || {
    echo "[ERROR] Build failed. Check CMake/gRPC installation."
    exit 1
}
echo "[OK] Build successful: bin/rawhash2"

# Step 2: Build R10 index
echo ""
echo "============================================"
echo "[2/4] Building R10 index from E. coli ref"
echo "============================================"
bin/rawhash2 -x sensitive --r10 \
    -p extern/local_kmer_models/uncalled_r1041_model_only_means.txt \
    -d "$WORK_DIR/test.idx" test/data/d9_ecoli_r1041/ref.fa || {
    echo "[ERROR] Index build failed."
    exit 1
}
echo "[OK] Index created: $WORK_DIR/test.idx"

# Step 3: Start Icarust simulator in background
echo ""
echo "============================================"
echo "[3/4] Starting Icarust simulator"
echo "============================================"

# Icarust needs to run from its own directory (for static/ kmer models)
# Create a config.ini pointing to its TLS certs
ICARUST_INI="$WORK_DIR/icarust_config.ini"
cat > "$ICARUST_INI" <<EOF
[TLS]
cert-dir = $ICARUST_CERTS/

[PORTS]
manager = 10000
position = 10001

[SEQUENCER]
channels = 3000
EOF

# Create simulation profile with absolute paths
# target_yield must be > global_mean_read_length * channels (8000 * 3000 = 24M)
# Using 100M to be safe
ICARUST_TOML="$WORK_DIR/icarust_test_config.toml"
cat > "$ICARUST_TOML" <<EOF
output_path = "$WORK_DIR/icarust_output/"
target_yield = 100000000
global_mean_read_length = 8000
pore_type = "R10"
nucleotide_type = "DNA"
random_seed = 42

[parameters]
sample_name = "test_ecoli"
experiment_name = "rawhash2_live_test"
flowcell_name = "FAQ1234"
experiment_duration_set = $((LIVE_DURATION + 30))
sample_rate = 4000
sequencing_speed = 400
device_id = "SimDevice"
position = "SimPosition"

[[sample]]
name = "E_coli_CFT073"
input_genome = "$RAWHASH2_ROOT/test/data/d9_ecoli_r1041/ref.fa"
mean_read_length = 8000
weight = 1
EOF

mkdir -p "$WORK_DIR/icarust_output"

# Run Icarust from its directory so it can find static/ kmer models
(cd "$ICARUST_DIR" && "$ICARUST_BIN" -s "$ICARUST_TOML" -c "$ICARUST_INI") \
    > "$WORK_DIR/icarust.log" 2>&1 &
ICARUST_PID=$!
echo "[OK] Icarust started (PID: $ICARUST_PID)"

# Wait for Icarust to initialize (10-15s is typical)
echo "[Setup] Waiting for Icarust to initialize..."
sleep 15

# Verify Icarust is running
if ! kill -0 $ICARUST_PID 2>/dev/null; then
    echo "[ERROR] Icarust process died during startup."
    echo ""
    echo "Last 20 lines of Icarust log:"
    tail -20 "$WORK_DIR/icarust.log" 2>/dev/null
    echo ""
    echo "Common causes:"
    echo "  - Expired TLS certificates (see LIVE.md troubleshooting)"
    echo "  - InvalidProbability error (increase target_yield in TOML config)"
    echo "  - Missing reference genome file"
    exit 1
fi
echo "[OK] Icarust is running and ready"

# Step 4: Run RawHash2 live mapping
echo ""
echo "============================================"
echo "[4/4] Running RawHash2 in live mode"
echo "============================================"
echo "[Info] Mapping reads as they arrive from Icarust..."
echo "[Info] PAF output: $WORK_DIR/live_test.paf"
echo "[Info] Log output: $WORK_DIR/live_test_stderr.log"
echo "[Info] Duration: ${LIVE_DURATION}s, Channels: 1-${CHANNELS}"
echo ""

# Use --live-duration for timeout (works on both macOS and Linux)
# Icarust uses TLS, so we need --live-tls with the CA cert
bin/rawhash2 --live \
    --live-port 10001 \
    --live-tls \
    --live-tls-cert "$ICARUST_CA" \
    --live-first-channel 1 \
    --live-last-channel "$CHANNELS" \
    --live-duration "$LIVE_DURATION" \
    -t 4 \
    "$WORK_DIR/test.idx" \
    > "$WORK_DIR/live_test.paf" 2>"$WORK_DIR/live_test_stderr.log" || {
    EXIT_CODE=$?
    echo "[WARN] RawHash2 exited with code $EXIT_CODE"
}

# Show log tail
echo ""
echo "[Log] Last 10 lines of stderr:"
tail -10 "$WORK_DIR/live_test_stderr.log"

# Cleanup
echo ""
echo "[Cleanup] Stopping Icarust..."
kill $ICARUST_PID 2>/dev/null || true
wait $ICARUST_PID 2>/dev/null || true

# Summary
echo ""
echo "============================================"
echo "Test Complete"
echo "============================================"

# Report results
if [ -f "$WORK_DIR/live_test.paf" ] && [ -s "$WORK_DIR/live_test.paf" ]; then
    TOTAL_LINES=$(wc -l < "$WORK_DIR/live_test.paf")
    # Count mapped (non-zero MAPQ or has reference name != '*')
    MAPPED=$(awk '$6 != "*"' "$WORK_DIR/live_test.paf" | wc -l)
    UNMAPPED=$(awk '$6 == "*"' "$WORK_DIR/live_test.paf" | wc -l)

    echo "[OK] Results saved to: $WORK_DIR/live_test.paf"
    echo ""
    echo "Summary:"
    echo "  Total PAF lines:  $TOTAL_LINES"
    echo "  Mapped reads:     $MAPPED"
    echo "  Unmapped reads:   $UNMAPPED"

    if [ $TOTAL_LINES -gt 0 ]; then
        # Show MAPQ distribution
        echo ""
        echo "MAPQ distribution:"
        awk '{print $12}' "$WORK_DIR/live_test.paf" | sort -n | uniq -c | sort -rn | head -10 | awk '{printf "  MAPQ %d: %d reads\n", $2, $1}'

        # Show chunks-to-map distribution
        echo ""
        echo "Chunks to map:"
        grep 'ci:i:' "$WORK_DIR/live_test.paf" | sed 's/.*ci:i:\([0-9]*\).*/\1/' | sort -n | uniq -c | sort -rn | head -10 | awk '{printf "  %d chunks: %d reads\n", $2, $1}'
    fi

    echo ""
    echo "Files:"
    echo "  PAF output:   $WORK_DIR/live_test.paf"
    echo "  Stderr log:   $WORK_DIR/live_test_stderr.log"
    echo "  Icarust log:  $WORK_DIR/icarust.log"
    echo "  Icarust data: $WORK_DIR/icarust_output/"
else
    echo "[ERROR] No output or empty output file."
    echo "[Info] Check $WORK_DIR/live_test_stderr.log for errors."
    cat "$WORK_DIR/live_test_stderr.log"
    exit 1
fi

echo ""
echo "Done!"
