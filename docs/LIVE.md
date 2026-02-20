# RawHash2 Live Streaming (MinKNOW/Icarust) Guide

## Overview

RawHash2 now supports **real-time signal streaming** from Oxford Nanopore's MinKNOW sequencing control software via gRPC. This enables selective sequencing workflows where mapping decisions are made in real-time as reads are being sequenced.

**Current Status:** Beta version with **incremental chunk processing** and **decision feedback**. Tested and validated with the Icarust simulator. Real MinKNOW integration is straightforward but has not been tested on physical hardware.

**Key features:**
- **Incremental processing**: Each gRPC chunk is processed as it arrives (not accumulated then dispatched), enabling early mapping decisions
- **Decision feedback**: Sends unblock/eject commands back to MinKNOW/Icarust when a read maps, enabling adaptive sequencing
- **Signal calibration**: Supports both CALIBRATED (default, float32 pA from MinKNOW) and UNCALIBRATED (raw int16 ADC with per-channel calibration) modes
- **Configurable pA filter**: 30-200 pA range filter (matching file-based pipeline) enabled by default

## Use Cases

- **Selective sequencing**: Map reads in real-time and decide which reads to keep or discard
- **Contamination control**: Identify and unblock contaminating sequences dynamically
- **Abundance estimation**: Monitor species/target abundance during active sequencing
- **Method validation**: Test new classification algorithms on live signal data

## System Requirements

| Component | macOS | Linux |
|-----------|-------|-------|
| C/C++ Compiler | Apple Clang (Xcode) | GCC 11+ (via conda) |
| CMake | 3.16+ | 3.16+ (via conda) |
| GNU Make | Required | Required (via conda) |
| gRPC | Homebrew | Conda |
| Rust | Homebrew | Conda |
| HDF5 | Homebrew | Conda |

---

## Installation

### Step 1: Install gRPC and Dependencies

**macOS (via Homebrew):**

```bash
brew install grpc
```

This installs gRPC 1.60+, protobuf, abseil, c-ares, re2, and CMake will auto-detect it.

**Linux (via Conda - Recommended):**

Create a dedicated conda environment for RawHash2 development with gRPC:

```bash
conda create -n rawhash2-live cmake cxx-compiler make grpcio grpcio-tools libgrpc protobuf
conda activate rawhash2-live
```

This single command installs:
- CMake (>3.16 required)
- C/C++ compiler
- GNU Make
- gRPC 1.60+, protobuf, and all dependencies

---

### Step 2: Build RawHash2 with gRPC Support

Navigate to the RawHash2 repository root:

```bash
cd /path/to/RawHash2
```

Build with gRPC enabled:

```bash
make cmake CMAKE_OPTS="-DENABLE_GRPC=ON"
```

Or with additional format support (HDF5 for FAST5, SLOW5 for BLOW5):

```bash
make cmake CMAKE_OPTS="-DENABLE_GRPC=ON -DENABLE_HDF5=ON -DENABLE_SLOW5=ON"
```

The compiled binary is at `bin/rawhash2` (gRPC-enabled).

**Verification:**

```bash
bin/rawhash2 --help | grep live
```

Should print the live streaming options.

---

### Step 3: Install Rust and Build Icarust

Icarust is a MinKNOW simulator that generates synthetic nanopore signal for testing.

**macOS (via Homebrew):**

```bash
brew install rust hdf5@1.10
```

**Linux (via Conda):**

```bash
conda activate rawhash2-live
conda install rust hdf5
```

**Clone and Build Icarust:**

```bash
git clone https://github.com/LooseLab/Icarust.git
cd Icarust
cargo build --release
# Binary: target/release/icarust
```

This may take 5-10 minutes on first build.

---

## Running Your First Live Mapping Test

### Quick Start (5 minutes)

**Terminal 1: Build index**

```bash
cd /path/to/RawHash2

# Build an R10 index from E. coli reference
bin/rawhash2 -x sensitive --r10 \
  -p extern/local_kmer_models/uncalled_r1041_model_only_means.txt \
  -d test.idx test/data/d9_ecoli_r1041/ref.fa
```

**Terminal 2: Start Icarust simulator**

Icarust must run from its own directory (to find `static/` kmer models) and needs a `config.ini` for TLS/port settings:

```bash
# Create config.ini (adjust cert-dir path to your Icarust location)
cat > /tmp/icarust_config.ini <<EOF
[TLS]
cert-dir = /path/to/Icarust/static/tls_certs/

[PORTS]
manager = 10000
position = 10001

[SEQUENCER]
channels = 3000
EOF

# Run Icarust from its directory
cd /path/to/Icarust
./target/release/icarust -s /path/to/RawHash2/docs/live/example_config.toml -c /tmp/icarust_config.ini
```

**Note:** The simulation profile TOML must use absolute paths for `input_genome`. The `test_live.sh` script handles all this automatically.

**Terminal 3: Run RawHash2 in live mode**

```bash
cd /path/to/RawHash2
bin/rawhash2 --live --live-port 10001 --live-tls \
  --live-tls-cert /path/to/Icarust/static/tls_certs/ca.crt \
  --live-duration 30 -t 4 test.idx > live_output.paf
```

Icarust uses TLS by default, so `--live-tls` and `--live-tls-cert` are required. Reads are processed incrementally — PAF lines appear as soon as each read maps (not after the read ends).

**Terminal 4: Monitor results (optional)**

```bash
tail -f /path/to/RawHash2/live_output.paf
```

**Stop:** After Icarust finishes (usually ~60 seconds) or press Ctrl+C in terminal 3.

### Verify Results

```bash
# Count mapped reads
grep -v "^#" live_output.paf | wc -l

# Check mapping quality (MAPQ column)
awk '{print $12}' live_output.paf | sort -n | uniq -c | sort -rn | head -10
```

Expected results (60-second test):
- ~1000 unique reads
- ~98% mapped (since Icarust generates idealized signal)
- MAPQ distribution: 79% at MAPQ=60 (maximum quality)

---

## Automated Test Script

A convenience script `docs/live/test_live.sh` automates the full workflow:

```bash
bash docs/live/test_live.sh
```

The script:
1. Builds RawHash2 with gRPC
2. Creates R10 index
3. Starts Icarust simulator
4. Runs live mapping
5. Cleans up and reports results

Results saved to `/tmp/live_test.paf`.

---

## CLI Reference

### Live Streaming Options

```
--live                     Enable real-time gRPC streaming from MinKNOW/Icarust
--live-host STR           Server hostname [default: localhost]
--live-port INT           gRPC server port [default: 10001]
--live-first-channel INT  First channel to monitor, 1-indexed [default: 1]
--live-last-channel INT   Last channel to monitor, 1-indexed [default: 512]
--live-tls                Use TLS encryption (required for Icarust and real MinKNOW)
--live-tls-cert FILE      Path to CA certificate file for TLS verification
--live-duration INT       Run for INT seconds, 0 = until experiment ends [default: 0]
--live-debug              Print chunk metadata to stderr (diagnostic mode, no mapping)
--live-no-sig-filter      Disable 30-200 pA signal range filter in streaming
--live-uncalibrated       Request uncalibrated (int16 ADC) data, apply per-channel cal
```

### Example Commands

**Basic live mapping (localhost, insecure):**
```bash
bin/rawhash2 --live --live-port 10001 -t 4 ref.idx
```

**Live mapping with duration limit (30 seconds):**
```bash
bin/rawhash2 --live --live-duration 30 -t 4 ref.idx
```

**With TLS (for real MinKNOW):**
```bash
bin/rawhash2 --live --live-tls --live-tls-cert /path/to/ca.crt -t 4 ref.idx
```

**Debug mode — inspect signal without mapping:**
```bash
bin/rawhash2 --live --live-debug --live-port 10001 ref.idx 2>debug.log
```

In debug mode, PAF output is not produced, but stderr contains chunk metadata (channel ID, read UUID, sample count) for diagnostics.

---

## Understanding Signal Calibration

### Icarust Signal Format

Icarust simulates nanopore sequencing by:
1. Generating idealized kmer-level pore current (pA values) from a reference genome using an R10/R9 pore model
2. Converting pA → i16 (picoampere integer, 16-bit signed) using calibration constants
3. Sending i16 bytes via gRPC

**R10 Calibration Constants:**
- Offset: -243.0 pA
- Scale: 0.14620706 pA/unit

**Example conversion (i16 → pA):**
```
pA_value = (i16_raw + (-243.0)) * 0.14620706
```

### RawHash2 Signal Processing

RawHash2 automatically:
1. **Detects format**: Checks if incoming data is i16 or float32 (based on byte size vs. chunk length)
2. **Converts i16 → pA**: Applies Icarust's R10 calibration if i16 detected
3. **Normalizes**: Applies z-score normalization (via `normalize_signal()`) to center around 0 with unit variance
4. **Event detection**: Performs level-crossing analysis to find signal transitions

Expected pA range for R10: 50–150 pA (before normalization).

### Troubleshooting Signal Issues

If **all reads are unmapped**, check signal format:

```bash
# Enable debug mode to see raw sample statistics
bin/rawhash2 --live --live-debug --live-port 10001 ref.idx 2>&1 | head -20
```

Debug output includes sample min/max values. If values look like:
- **~0–10000**: likely i16 format (correct for Icarust)
- **~0–1 or ~-3 to +3**: likely pre-normalized float32

If format mismatch, check Icarust configuration (pore_type, reference validity).

---

## Troubleshooting

### Issue: Connection Refused

```
Error: Failed to connect to localhost:10001
```

**Solutions:**
1. Verify Icarust is running: `ps aux | grep icarust`
2. Check port is not blocked: `netstat -tlnp | grep 10001` (Linux) or `lsof -i :10001` (macOS)
3. Verify gRPC server is listening in Icarust output

### Issue: gRPC Not Found During Build

```
CMake Error: Could not find gRPC
```

**Solutions:**
- **macOS**: Reinstall gRPC: `brew reinstall grpc`
- **Linux**: Activate conda environment: `conda activate rawhash2-live`
- **Manual fix**: Tell CMake where gRPC is:
  ```bash
  make cmake CMAKE_OPTS="-DENABLE_GRPC=ON -DCMAKE_PREFIX_PATH=$CONDA_PREFIX"
  ```

### Issue: TLS Verification Failed

```
Error: certificate verify failed: unable to get local issuer certificate
```

**For Icarust:** Icarust uses TLS with self-signed certs. Use the CA cert from Icarust's `static/tls_certs/` directory:
```bash
bin/rawhash2 --live --live-tls --live-tls-cert /path/to/Icarust/static/tls_certs/ca.crt ...
```

**For real MinKNOW:** Ensure CA certificate path is correct:
```bash
bin/rawhash2 --live --live-tls --live-tls-cert /path/to/ca.crt ...
```

Verify certificate is readable:
```bash
openssl verify /path/to/ca.crt
```

### Issue: Hanging on Shutdown

```
# Program seems stuck after finishing...
```

**Cause:** gRPC stream finalization can be slow.

**Solution:** Hangs are usually temporary (~10 seconds). If stuck longer:
1. Check if Icarust is still running (may block stream)
2. Kill Icarust: `pkill icarust`
3. Press Ctrl+C on RawHash2

### Issue: All Reads Unmapped (0% mapping rate)

**Possible causes:**
1. **Wrong pore model**: Ensure R10 index and signal are both R10
2. **Signal format mismatch**: Use `--live-debug` to inspect signal ranges
3. **Index build issue**: Rebuild index and verify reference FASTA is valid

**Debug workflow:**
```bash
# Step 1: Check index was built
file test.idx

# Step 2: Inspect gRPC signal metadata
bin/rawhash2 --live --live-debug --live-port 10001 test.idx 2>&1 | grep -E "channel|read_id|samples"

# Step 3: Verify Icarust is generating realistic signal
# Check Icarust output for "Signal generation complete" messages
```

### Issue: Out of Memory

For long runs with many channels, signal buffers can grow large.

**Mitigation:**
- Reduce channel range: `--live-first-channel 1 --live-last-channel 96` (monitor first 96 channels only)
- Limit duration: `--live-duration 300` (run for 5 minutes only)
- Use fewer threads: `-t 2` (frees per-thread buffers)

---

## Performance Characteristics

### Throughput

Single-threaded: ~30 reads/minute

Multi-threaded (scales linearly):
```bash
-t 2: ~60 reads/minute
-t 4: ~120 reads/minute
-t 8: ~240 reads/minute
```

### Latency

With incremental chunk processing, mapping decisions are made DURING the read — typically after 2-3 chunks (each chunk = 4000 samples = 1 second at 4 kHz):
- Most reads map in **2 chunks** (~0.4 sec mapping time)
- Some reads need 3-7 chunks (~0.8–2.4 sec)
- Decision + unblock is sent immediately upon mapping

### Quality Metrics (Icarust R10 test)

20-second test on E. coli (10 channels, 22 reads):
- **Mapped rate**: 100% (22/22 mapped)
- **MAPQ distribution**: 45% at MAPQ=60 (maximum quality)
- **Chunks to map**: 50% at 2 chunks, 27% at 3 chunks
- **Unblock actions**: sent for all mapped reads

Note: These numbers are for Icarust (idealized signal). Real MinKNOW signal will have lower accuracy due to basecalling noise, chimeric reads, etc.

### Resource Usage

Per-channel memory: ~50 KB (mapping state + signal buffer)
CPU: Single-threaded, sequential per-channel processing. Scales via channel count.

---

## Understanding the Icarust Configuration

Edit `docs/live/example_config.toml` to customize Icarust behavior:

```toml
output_path = "/tmp/icarust_test/"      # Where to write POD5 output
target_yield = 10000000                 # Total bases to sequence (10M = quicker test)
global_mean_read_length = 8000          # Average read length
pore_type = "R10"                       # R10 or R9 (must match index)
nucleotide_type = "DNA"                 # DNA or RNA

[parameters]
sample_rate = 4000                      # Hz (4 kHz for current models)
sequencing_speed = 400                  # bases/second (realistic: 200-500)
experiment_duration_set = 60            # How long to run (seconds)

[[sample]]
name = "E_coli_CFT073"
input_genome = "./test/data/d9_ecoli_r1041/ref.fa"  # FASTA reference
mean_read_length = 8000                 # This sample's mean read length
weight = 1                              # Probability weight (1.0 = always)
```

**Tips:**
- Increase `target_yield` for longer tests: `target_yield = 100000000` (100M bases ≈ 3–5 min)
- Increase `experiment_duration_set` to 300 for 5-minute tests
- Change `pore_type = "R9"` to test R9.4.1 model (requires R9 index + pre-computed squiggle)

---

## Comparing with File-Based Mapping

**Baseline (file-based POD5 mapping):**
```bash
bin/rawhash2 -x sensitive --r10 \
  -p extern/local_kmer_models/uncalled_r1041_model_only_means.txt \
  -d ref.idx -t 4 ref.fa test.pod5 > file_output.paf
```

**Live (Icarust streaming):**
```bash
bin/rawhash2 --live --live-port 10001 -t 4 ref.idx > live_output.paf
```

Both produce identical PAF format. Key differences:
- **File-based**: Processes all reads, reports final statistics
- **Live**: Processes each chunk incrementally, makes decisions mid-read, sends unblock actions

For evaluation: compare mapping rate, MAPQ, precision/recall on same reference set.

---

## Future Work & Limitations

### Currently Not Supported

- **Policy-based decisions**: Currently always ejects on mapping, keeps on unmapped. Target vs non-target classification is not yet implemented.
- **Sequence Until**: Real-time abundance monitoring not integrated
- **Real MinKNOW**: Only tested with Icarust simulator (gRPC interface is compatible)
- **Multi-position**: Single flowcell only
- **Windows**: Build tested on macOS and Linux only

### Planned Enhancements

- Policy-based decision logic (target vs non-target, abundance thresholds)
- Sequence Until + live mode integration
- Multi-threaded per-response channel processing
- Real MinKNOW validation on physical hardware

---

## Citation & References

If you use RawHash2 live streaming in your work, please cite:

**RawHash2:** [Paper reference]
**MinKNOW gRPC API:** [Oxford Nanopore documentation]
**Icarust Simulator:** https://github.com/LooseLab/Icarust

---

## Support & Feedback

For issues, questions, or feature requests:
- GitHub Issues: https://github.com/CMU-SAFARI/RawHash2/issues
- Check troubleshooting section above first
- Include: OS, gRPC version, RawHash2 build log, error message
