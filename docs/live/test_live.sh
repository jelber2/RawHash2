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
#   - gRPC libraries installed (brew install grpc protobuf on macOS)
#
# Usage:
#   bash test_live.sh
#
# Environment variables:
#   ICARUST_DIR    Path to Icarust repo (default: ../../Icarust relative to this script)
#   LIVE_DURATION  Seconds to run (default: 30)
#   CHANNELS       Number of channels to monitor (default: 10)
#
# Results:
#   - /tmp/live_test.paf: PAF output from live mapping
#   - /tmp/live_test_stderr.log: RawHash2 log messages
#   - /tmp/icarust_test/: Icarust-generated POD5 files

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

# Detect platform and set environment
if [[ "$OSTYPE" == "darwin"* ]]; then
    export HDF5_DIR=$(brew --prefix hdf5@1.10)
    echo "[Platform] macOS detected (HDF5_DIR=$HDF5_DIR)"
else
    # Activate conda environment if available
    if command -v conda &>/dev/null; then
        source $(conda info --base)/etc/profile.d/conda.sh
        conda activate rawhash2-live 2>/dev/null || true
        echo "[Platform] Linux detected (conda rawhash2-live environment)"
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
    -d /tmp/test.idx test/data/d9_ecoli_r1041/ref.fa || {
    echo "[ERROR] Index build failed."
    exit 1
}
echo "[OK] Index created: /tmp/test.idx"

# Step 3: Start Icarust simulator in background
echo ""
echo "============================================"
echo "[3/4] Starting Icarust simulator"
echo "============================================"

# Icarust needs to run from its own directory (for static/ kmer models)
# Create a config.ini pointing to its TLS certs
ICARUST_INI="/tmp/icarust_config.ini"
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
ICARUST_TOML="/tmp/icarust_test_config.toml"
cat > "$ICARUST_TOML" <<EOF
output_path = "/tmp/icarust_test/"
target_yield = 10000000
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

mkdir -p /tmp/icarust_test

# Run Icarust from its directory so it can find static/ kmer models
(cd "$ICARUST_DIR" && "$ICARUST_BIN" -s "$ICARUST_TOML" -c "$ICARUST_INI") &
ICARUST_PID=$!
echo "[OK] Icarust started (PID: $ICARUST_PID)"

# Wait for Icarust to initialize
echo "[Setup] Waiting for Icarust to initialize..."
sleep 5

# Verify Icarust is running
if ! kill -0 $ICARUST_PID 2>/dev/null; then
    echo "[ERROR] Icarust process died. Check configuration."
    exit 1
fi
echo "[OK] Icarust is running and ready"

# Step 4: Run RawHash2 live mapping
echo ""
echo "============================================"
echo "[4/4] Running RawHash2 in live mode"
echo "============================================"
echo "[Info] Mapping reads as they arrive from Icarust..."
echo "[Info] PAF output: /tmp/live_test.paf"
echo "[Info] Log output: /tmp/live_test_stderr.log"
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
    /tmp/test.idx \
    > /tmp/live_test.paf 2>/tmp/live_test_stderr.log || {
    EXIT_CODE=$?
    echo "[WARN] RawHash2 exited with code $EXIT_CODE"
}

# Show log tail
echo ""
echo "[Log] Last 10 lines of stderr:"
tail -10 /tmp/live_test_stderr.log

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
if [ -f /tmp/live_test.paf ] && [ -s /tmp/live_test.paf ]; then
    TOTAL_LINES=$(wc -l < /tmp/live_test.paf)
    # Count mapped (non-zero MAPQ or has reference name != '*')
    MAPPED=$(awk '$6 != "*"' /tmp/live_test.paf | wc -l)
    UNMAPPED=$(awk '$6 == "*"' /tmp/live_test.paf | wc -l)

    echo "[OK] Results saved to: /tmp/live_test.paf"
    echo ""
    echo "Summary:"
    echo "  Total PAF lines:  $TOTAL_LINES"
    echo "  Mapped reads:     $MAPPED"
    echo "  Unmapped reads:   $UNMAPPED"

    if [ $TOTAL_LINES -gt 0 ]; then
        # Show MAPQ distribution
        echo ""
        echo "MAPQ distribution:"
        awk '{print $12}' /tmp/live_test.paf | sort -n | uniq -c | sort -rn | head -10 | awk '{printf "  MAPQ %d: %d reads\n", $2, $1}'

        # Show chunks-to-map distribution
        echo ""
        echo "Chunks to map:"
        grep 'ci:i:' /tmp/live_test.paf | sed 's/.*ci:i:\([0-9]*\).*/\1/' | sort -n | uniq -c | sort -rn | head -10 | awk '{printf "  %d chunks: %d reads\n", $2, $1}'
    fi

    echo ""
    echo "Files:"
    echo "  PAF output:   /tmp/live_test.paf"
    echo "  Stderr log:   /tmp/live_test_stderr.log"
    echo "  Icarust POD5: /tmp/icarust_test/"
else
    echo "[ERROR] No output or empty output file."
    echo "[Info] Check /tmp/live_test_stderr.log for errors."
    cat /tmp/live_test_stderr.log
    exit 1
fi

echo ""
echo "Done!"
