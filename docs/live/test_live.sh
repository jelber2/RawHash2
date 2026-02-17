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
# Usage:
#   bash test_live.sh
#
# Results:
#   - /tmp/live_test.paf: PAF output from live mapping
#   - /tmp/icarust_test/: Icarust-generated POD5 files

set -e

# Detect platform and set environment
if [[ "$OSTYPE" == "darwin"* ]]; then
    export HDF5_DIR=$(brew --prefix hdf5@1.10)
    echo "[Platform] macOS detected (HDF5_DIR=$HDF5_DIR)"
else
    # Activate conda environment
    source $(conda info --base)/etc/profile.d/conda.sh
    conda activate rawhash2-live
    echo "[Platform] Linux detected (conda rawhash2-live environment activated)"
fi

# Navigate to RawHash2 root
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RAWHASH2_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
cd "$RAWHASH2_ROOT"
echo "[Setup] Working directory: $RAWHASH2_ROOT"

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
./Icarust/target/release/icarust docs/live/example_config.toml &
ICARUST_PID=$!
echo "[OK] Icarust started (PID: $ICARUST_PID)"

# Wait for Icarust to initialize (listen on port 10001)
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
echo "[Info] Output: /tmp/live_test.paf"
echo "[Info] Press Ctrl+C to stop early (or wait ~60 seconds)"
echo ""

# Run with 90-second timeout (Icarust runs for ~60 seconds)
timeout 90 bin/rawhash2 --live --live-port 10001 -t 4 /tmp/test.idx > /tmp/live_test.paf 2>&1 || {
    EXIT_CODE=$?
    # timeout returns 124, which is expected when Icarust finishes
    if [ $EXIT_CODE -ne 124 ]; then
        echo "[ERROR] RawHash2 failed with exit code $EXIT_CODE"
    fi
}

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
if [ -f /tmp/live_test.paf ]; then
    TOTAL_LINES=$(wc -l < /tmp/live_test.paf)
    MAPPED=$(grep -v "^#" /tmp/live_test.paf | wc -l)

    echo "[OK] Results saved to: /tmp/live_test.paf"
    echo ""
    echo "Summary:"
    echo "  Total PAF lines:  $TOTAL_LINES"
    echo "  Mapped reads:     $MAPPED"

    if [ $TOTAL_LINES -gt 0 ]; then
        PERCENT=$(awk "BEGIN {printf \"%.1f\", 100.0*$MAPPED/$TOTAL_LINES}")
        echo "  Mapping rate:     ${PERCENT}%"

        # Show MAPQ distribution
        echo ""
        echo "MAPQ distribution (best per unique read):"
        awk '{print $12}' /tmp/live_test.paf | sort -n | uniq -c | sort -rn | awk '{if(NR<=5) printf "  MAPQ %d: %d reads\n", $2, $1}'
    fi

    echo ""
    echo "Next steps:"
    echo "  1. View full results: cat /tmp/live_test.paf"
    echo "  2. Compare with file-based: bin/rawhash2 -x sensitive --r10 -p extern/local_kmer_models/uncalled_r1041_model_only_means.txt -d ref.idx -t 4 ref.fa test.pod5"
    echo "  3. Read docs: less docs/LIVE.md"
else
    echo "[ERROR] No output file. Check RawHash2 logs above."
    exit 1
fi

echo ""
echo "Done!"
