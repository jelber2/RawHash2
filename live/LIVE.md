# RawHash2 Live Mode: MinKNOW Integration and Adaptive Sampling

## Overview

RawHash2 supports **real-time adaptive sampling** from Oxford Nanopore sequencers via the MinKNOW gRPC API. Signal chunks stream in as reads are being sequenced, RawHash2 maps each chunk incrementally, and mapping decisions (keep or eject) are sent back to the sequencer — all within the time budget of active sequencing.

This guide covers three usage modes, from development testing to production sequencing:

| Mode | Signal source | Use case |
|------|--------------|----------|
| **Pod5 replay** | `pod5_replay_server.py` replays a real pod5 file over gRPC | Deterministic validation and benchmarking |
| **Icarust simulation** | [Icarust](https://github.com/LooseLab/Icarust) synthesizes signal from a reference | End-to-end integration testing with simulated hardware |
| **Real MinKNOW** | Physical nanopore sequencer | Production adaptive sampling |

All three share the same RawHash2 `--live` interface — only the gRPC endpoint differs.

---

## Table of Contents

- [Quick Reference: End-to-End Workflow](#quick-reference-end-to-end-workflow)
- [Step 1: Install Dependencies](#step-1-install-dependencies)
- [Step 2: Build RawHash2 with gRPC](#step-2-build-rawhash2-with-grpc)
- [Step 3: Build the Index (Offline)](#step-3-build-the-index-offline)
- [Step 4: Run Live Mapping (Online)](#step-4-run-live-mapping-online)
  - [Option A: Pod5 Replay Server](#option-a-pod5-replay-server)
  - [Option B: Icarust Simulator](#option-b-icarust-simulator)
  - [Option C: Real MinKNOW Sequencer](#option-c-real-minknow-sequencer)
- [CLI Reference](#cli-reference)
- [Architecture and Threading](#architecture-and-threading)
- [Signal Calibration](#signal-calibration)
- [Validation Framework](#validation-framework)
- [Troubleshooting](#troubleshooting)
- [Icarust Configuration Reference](#icarust-configuration-reference)

---

## Quick Reference: End-to-End Workflow

For those who want the shortest path from clone to running live mapping:

```bash
# 1. Clone
git clone --recursive https://github.com/STORMgroup/RawHash2.git rawhash2
cd rawhash2

# 2. Set up conda environment with gRPC
conda create -n rawhash2-live cmake make cxx-compiler grpcio grpcio-tools libgrpc protobuf
conda activate rawhash2-live

# 3. Build with gRPC support
make cmake CMAKE_OPTS="-DENABLE_GRPC=ON"

# 4. Index a reference (offline, one-time)
bin/rawhash2 -x viral \
  -p extern/kmer_models/legacy/legacy_r9.4_180mv_450bps_6mer/template_median68pA.model \
  -d ref.idx test/data/d1_sars-cov-2_r94/ref.fa

# 5. Start a replay server (terminal 1)
pip install grpcio grpcio-tools pod5
python3 pod5_replay_server.py \
  --pod5 test/data/d1_sars-cov-2_r94/small_pod5_files/small.pod5 \
  --port 10111 --mode uncalibrated --chunk-size 4000

# 6. Map live (terminal 2)
bin/rawhash2 --live --live-port 10111 \
  --live-uncalibrated --live-no-sig-filter \
  -x viral -t 16 ref.idx > live.paf
```

---

## Step 1: Install Dependencies

### macOS (Homebrew)

```bash
brew install grpc cmake
```

This installs gRPC, protobuf, abseil, c-ares, re2 — CMake detects them automatically.

### Linux (Conda — recommended)

```bash
conda create -n rawhash2-live \
  cmake make cxx-compiler \
  grpcio grpcio-tools libgrpc protobuf
conda activate rawhash2-live
```

This provides:
- CMake 3.16+ and GCC 11+ (required for C++14 / gRPC)
- gRPC 1.60+ with all transitive dependencies
- protoc compiler for proto code generation

> **Note:** gRPC requires C++14. The conda `cxx-compiler` package satisfies this. System GCC 8.x will **not** work.

### Python dependencies (for pod5 replay server only)

```bash
pip install grpcio grpcio-tools pod5
```

### Proto file compilation (for the Python replay server)

The pod5 replay server needs compiled Python protobuf stubs. Run this once:

```bash
PROTO_DIR=/path/to/rawhash2/proto
OUT_DIR=./proto_gen

mkdir -p ${OUT_DIR}/minknow_api
python3 -m grpc_tools.protoc \
  --proto_path=${PROTO_DIR} \
  --python_out=${OUT_DIR} --grpc_python_out=${OUT_DIR} \
  minknow_api/rpc_options.proto \
  minknow_api/device.proto \
  minknow_api/data.proto

touch ${OUT_DIR}/__init__.py ${OUT_DIR}/minknow_api/__init__.py
export PYTHONPATH="${OUT_DIR}:${PYTHONPATH}"
```

---

## Step 2: Build RawHash2 with gRPC

From the RawHash2 repository root:

```bash
make cmake CMAKE_OPTS="-DENABLE_GRPC=ON"
```

With additional signal format support:

```bash
make cmake CMAKE_OPTS="-DENABLE_GRPC=ON -DENABLE_HDF5=ON -DENABLE_SLOW5=ON"
```

Or invoke CMake directly for full control:

```bash
mkdir -p build && cd build
cmake -DENABLE_GRPC=ON ..
cmake --build . -j$(nproc)
cp src/rawhash2 ../bin/
```

**Verify the build:**

```bash
bin/rawhash2 --help 2>&1 | grep "live"
```

Should print the `--live` family of options.

### How gRPC compilation works internally

When `-DENABLE_GRPC=ON`:

1. CMake's `cmake/FetchGRPC.cmake` first tries `find_package(gRPC)` to locate a system/conda installation.
2. If not found, it falls back to `FetchContent` to build gRPC v1.60.0 from source (~20 minutes).
3. `generate_grpc_cpp()` in `src/CMakeLists.txt` runs `protoc` + `grpc_cpp_plugin` on the proto files under `proto/minknow_api/` to generate C++ service stubs.
4. The generated stubs are compiled into the `rawhash2` binary alongside `rlive.cpp`.

If CMake cannot find gRPC, point it explicitly:

```bash
make cmake CMAKE_OPTS="-DENABLE_GRPC=ON -DCMAKE_PREFIX_PATH=$CONDA_PREFIX"
```

---

## Step 3: Build the Index (Offline)

The index is built once from a reference FASTA, identical to regular file-based mapping. Choose the pore model matching your sequencing chemistry:

**R9.4 (legacy):**

```bash
bin/rawhash2 -x <preset> \
  -p extern/kmer_models/legacy/legacy_r9.4_180mv_450bps_6mer/template_median68pA.model \
  -d ref.idx -t 16 ref.fa
```

**R10.4.1:**

```bash
bin/rawhash2 -x <preset> --r10 \
  -p extern/local_kmer_models/uncalled_r1041_model_only_means.txt \
  -d ref.idx -t 16 ref.fa
```

**Presets:**

| Preset | Use case | Typical organisms |
|--------|----------|-------------------|
| `viral` | Viral genomes | SARS-CoV-2, influenza |
| `sensitive` | Small-medium genomes (<500M) | E. coli, yeast, Drosophila |
| `fast` | Large genomes (>500M) | Human |
| `faster` | Very large metagenomes (>10G) | Complex environmental samples |

> The preset, pore model, and `--r10` flag used for indexing **must match** what you use during live mapping. A mismatch will cause 0% mapping rate.

---

## Step 4: Run Live Mapping (Online)

All three modes use the same RawHash2 command — only the gRPC endpoint and TLS settings differ.

### Option A: Pod5 Replay Server

The pod5 replay server replays a real pod5 file over gRPC, simulating MinKNOW's `DataService.get_live_reads()` streaming exactly. This gives **deterministic, reproducible** results for validation and benchmarking.

**Terminal 1 — start the server:**

```bash
python3 pod5_replay_server.py \
  --pod5 /path/to/reads.pod5 \
  --port 10111 \
  --mode uncalibrated \
  --chunk-size 4000 \
  --first-channel 1 \
  --last-channel 512
```

Wait for `SERVER READY` on stderr.

Server options:
- `--mode calibrated`: send float32 pA values (MinKNOW default)
- `--mode uncalibrated`: send int16 ADC values (Icarust-compatible)
- `--chunk-size N`: samples per chunk (must match the `-c` / chunk_size used with rawhash2; default 4000)

**Terminal 2 — run RawHash2:**

```bash
bin/rawhash2 --live \
  --live-port 10111 \
  --live-first-channel 1 --live-last-channel 512 \
  --live-uncalibrated \
  --live-no-sig-filter \
  -x <preset> [--r10] -t 16 \
  ref.idx > live.paf
```

> **Calibrated vs. uncalibrated:** Use `--live-uncalibrated` to match `--mode uncalibrated` on the server. Omit it for `--mode calibrated`. The replay server also exposes a `DeviceService.get_calibration()` RPC, so RawHash2 can fetch per-channel calibration automatically.

### Option B: Icarust Simulator

[Icarust](https://github.com/LooseLab/Icarust) synthesizes realistic nanopore signal from a reference genome. It uses TLS by default.

**Build Icarust:**

```bash
# Install Rust
# macOS: brew install rust
# Linux: conda install rust

git clone https://github.com/LooseLab/Icarust.git
cd Icarust
cargo build --release
# Binary: target/release/icarust
```

**Create a simulation profile** (see [Icarust Configuration Reference](#icarust-configuration-reference) below, or use `live/example_config.toml`):

```bash
cd /path/to/Icarust
./target/release/icarust \
  -s /path/to/rawhash2/live/example_config.toml \
  -c /path/to/config.ini
```

Wait ~15 seconds for Icarust to initialize.

**Run RawHash2:**

```bash
bin/rawhash2 --live --live-port 10001 \
  --live-tls --live-tls-cert /path/to/Icarust/static/tls_certs/ca.crt \
  --live-uncalibrated --live-no-sig-filter \
  --live-duration 60 \
  -x sensitive --r10 -t 16 \
  ref.idx > live.paf
```

Key differences from replay mode:
- `--live-tls` and `--live-tls-cert` are required (Icarust uses self-signed TLS)
- `--live-duration 60` limits how long to stream (Icarust runs indefinitely)
- Icarust always sends UNCALIBRATED (int16 ADC) signal
- DeviceService calibration is not available (RawHash2 falls back to R10 defaults: offset=-243.0, scale=0.14620706)

### Option C: Real MinKNOW Sequencer

For production adaptive sampling on a physical nanopore sequencer:

```bash
bin/rawhash2 --live \
  --live-host <sequencer-hostname> \
  --live-port 8004 \
  --live-tls --live-tls-cert /path/to/minknow/ca.crt \
  --live-first-channel 1 --live-last-channel 512 \
  -x <preset> [--r10] -t 16 \
  ref.idx > live.paf
```

Notes:
- MinKNOW's default gRPC port is typically **8004** (position port), not 10001
- TLS certificates are in MinKNOW's installation directory (e.g., `/opt/ont/minknow/conf/rpc-certs/`)
- Use `--live-first-channel` / `--live-last-channel` to control which channels are monitored
- Omit `--live-duration` to run for the full experiment
- The default CALIBRATED mode is recommended for real MinKNOW (no `--live-uncalibrated`)
- RawHash2 sends `UnblockAction` decisions back through the bidirectional gRPC stream for mapped reads

**PromethION (3000+ channels):** Set `--live-last-channel 3000` and use `-t 32` or more. The parallel mapping phase scales well across threads.

---

## CLI Reference

### Live Streaming Options

| Flag | Default | Description |
|------|---------|-------------|
| `--live` | off | Enable real-time gRPC streaming mode |
| `--live-host STR` | `localhost` | gRPC server hostname |
| `--live-port INT` | `10001` | gRPC server port |
| `--live-first-channel INT` | `1` | First channel to monitor (1-indexed) |
| `--live-last-channel INT` | `512` | Last channel to monitor (1-indexed) |
| `--live-tls` | off | Use TLS encryption (required for Icarust and real MinKNOW) |
| `--live-tls-cert FILE` | none | Path to CA certificate for TLS verification |
| `--live-duration INT` | `0` | Run for N seconds; 0 = until experiment ends |
| `--live-debug` | off | Print chunk metadata to stderr (no mapping) |
| `--live-no-sig-filter` | off | Disable 30-200 pA signal range filter |
| `--live-uncalibrated` | off | Request UNCALIBRATED (int16 ADC) data with per-channel calibration |

### Standard mapping flags used with `--live`

| Flag | Description |
|------|-------------|
| `-x <preset>` | Mapping preset (`viral`, `sensitive`, `fast`, `faster`) |
| `--r10` | R10.4.1 pore model parameters |
| `-t INT` | Number of threads for parallel per-channel mapping |
| `-c INT` | Chunk size (samples per chunk; default 4000) |
| `--max-num-chunk INT` | Maximum chunks per read before declaring unmapped (default 5) |

### Example Commands

```bash
# Debug mode — inspect gRPC signal without mapping
bin/rawhash2 --live --live-debug --live-port 10111 ref.idx 2>debug.log

# Replay server, uncalibrated, 16 threads
bin/rawhash2 --live --live-port 10111 --live-uncalibrated -x viral -t 16 ref.idx > live.paf

# Icarust with TLS, 60-second run
bin/rawhash2 --live --live-port 10001 --live-tls \
  --live-tls-cert /path/to/ca.crt --live-duration 60 \
  --live-uncalibrated -x sensitive --r10 -t 16 ref.idx > live.paf

# Real MinKNOW, full experiment
bin/rawhash2 --live --live-host sequencer01 --live-port 8004 --live-tls \
  --live-tls-cert /opt/ont/minknow/conf/rpc-certs/ca.crt \
  --live-last-channel 3000 -x fast --r10 -t 32 ref.idx > live.paf
```

---

## Architecture and Threading

### Three-Phase Response Processing

Each gRPC response (containing up to one chunk per active channel) is processed in three phases:

```
Phase 1 (sequential):  Read boundary detection + signal extraction + calibration
Phase 2 (parallel):    kt_for() dispatches ri_map_one_chunk() across channels
Phase 3 (sequential):  Finalization + PAF output + gRPC decision feedback
```

**Phase 1** handles protobuf deserialization, read boundary tracking (detecting when a new read starts on a channel), signal format conversion (int16 to float32 pA), and the pA range filter. These are cheap operations and involve shared state (the `n_processed` counter).

**Phase 2** is the expensive phase — event detection, seeding, chaining, and DTW alignment. Each channel has its own independent `ri_reg1_t` (mapping state) and `ri_tbuf_t` (memory pool), so no locks are needed. `kt_for()` from kthread distributes work items across the thread pool.

**Phase 3** writes PAF output to stdout and sends `UnblockAction` decisions back through the gRPC stream — both require sequential access.

### Thread scaling

- `-t 1`: `kt_for()` degenerates to a sequential loop — identical to single-threaded behavior
- `-t N`: Up to N channels are mapped concurrently per response. Effective parallelism is `min(N, active_channels_in_response)`.
- For a MinION (512 channels), `-t 16` is a good default
- For a PromethION (3000+ channels), `-t 32` or more is recommended

---

## Signal Calibration

### Calibrated mode (default for real MinKNOW)

MinKNOW sends float32 pA values. No conversion needed — RawHash2 uses them directly.

### Uncalibrated mode (`--live-uncalibrated`)

The signal source sends raw int16 ADC values. RawHash2 converts using:

```
pA = (ADC + offset) * scale
```

Where calibration is obtained from (in priority order):
1. **DeviceService.get_calibration()** — per-channel offset and scale from the gRPC server (used by the pod5 replay server)
2. **Icarust R10 fallback** — hardcoded defaults (offset=-243.0, scale=0.14620706) used when DeviceService is unavailable

### pA range filter

By default, RawHash2 filters signal to the 30-200 pA range (matching the offline pipeline). Disable with `--live-no-sig-filter` for the rawest comparison against offline baselines.

---

## Validation Framework

The `rh2_eval/live_validation/` directory (outside the main repo) contains a systematic validation framework.

### Structure

```
rh2_eval/live_validation/
├── pod5_replay_server.py    # gRPC server replaying pod5 files
├── run_live_validation.sh   # Per-dataset validation (4 configs)
├── run_all.sh               # SLURM orchestrator for all datasets
├── compare_live_vs_baseline.py  # Per-read agreement analysis
├── summarize_results.py     # Cross-dataset summary table
├── setup_env.sh             # One-time Python proto compilation
├── proto_gen/               # Compiled Python protobuf stubs
└── results/                 # Output PAFs, logs, comparisons
```

### Running validation

**One-time setup:**

```bash
bash rh2_eval/live_validation/setup_env.sh
```

**Single dataset:**

```bash
bash rh2_eval/live_validation/run_live_validation.sh d1
```

This runs 4 configurations for dataset d1 (SARS-CoV-2, R9.4):

| Config | Signal mode | pA filter | Purpose |
|--------|-------------|-----------|---------|
| `cal_nofilter` | Calibrated (float32) | Disabled | Primary comparison vs offline baseline |
| `cal_filter` | Calibrated (float32) | Enabled | Default live behavior |
| `uncal_nofilter` | Uncalibrated (int16) | Disabled | Primary uncalibrated comparison |
| `uncal_filter` | Uncalibrated (int16) | Enabled | Default uncalibrated behavior |

Each config: starts replay server, runs `rawhash2 --live`, evaluates P/R/F1 against minimap2 ground truth, and compares per-read agreement with the offline baseline.

**All datasets (via SLURM):**

```bash
bash rh2_eval/live_validation/run_all.sh
```

Submits 10 dataset jobs + 1 Icarust sanity check + 1 summary aggregation job.

### Available datasets

| Key | Organism | Chemistry | Preset |
|-----|----------|-----------|--------|
| d1 | SARS-CoV-2 | R9.4 | viral |
| d2 | E. coli | R9.4 | sensitive |
| d3 | Yeast | R9.4 | sensitive |
| d4 | Green algae | R9.4 | sensitive |
| d5 | Human (NA12878) | R9.4 | fast |
| d6 | E. coli | R10.4 | sensitive |
| d7 | S. aureus | R10.4 | sensitive |
| d8 | Human (HG002) | R10.4.1 | fast |
| d9 | E. coli | R10.4.1 | sensitive |
| d10 | D. melanogaster | R10.4.1 | sensitive |

### What validation checks

- **Precision / Recall / F1** against minimap2 ground-truth PAF
- **Per-read agreement** with the offline file-based baseline (same reads, same reference):
  - Mapping status agreement (both mapped, both unmapped, discordant)
  - Target agreement among commonly-mapped reads
  - Position agreement (within +/-5000 bp)
- **Cal/uncal parity**: F1 difference between calibrated and uncalibrated configs should be <2%
- **Live/baseline parity**: Live nofilter F1 should be within 5% of the offline baseline

---

## Troubleshooting

### Build Issues

**gRPC not found:**

```
CMake Error: Could not find gRPC
```

Solutions:
- Activate conda environment: `conda activate rawhash2-live`
- Point CMake to gRPC: `CMAKE_OPTS="-DENABLE_GRPC=ON -DCMAKE_PREFIX_PATH=$CONDA_PREFIX"`
- macOS: `brew reinstall grpc`

**C++14 errors:**

gRPC requires C++14. If you see standard library errors, ensure you're using GCC 11+ (or Apple Clang).

### Connection Issues

**Connection refused:**

```
[E::connect] Connection to localhost:10111 timed out
```

- Verify the server is running and has printed `SERVER READY`
- Check port: `ss -tlnp | grep 10111` (Linux) or `lsof -i :10111` (macOS)
- Icarust takes ~15 seconds to initialize

**gRPC message too large:**

```
Received message larger than max (7299777 vs. 4194304)
```

The default gRPC max receive message size is 4MB. Calibrated mode with 512 channels can exceed this. The pod5 replay server sets a 256MB limit on its side; ensure the rawhash2 build also uses a sufficiently large limit. As a workaround, use uncalibrated mode (int16 is half the size of float32).

### TLS Issues

**Certificate verification failed:**

```
SSL routines::certificate verify failed
```

- For Icarust: pass `--live-tls-cert /path/to/Icarust/static/tls_certs/ca.crt`
- For MinKNOW: pass `--live-tls-cert /path/to/minknow/rpc-certs/ca.crt`
- Check expiration: `openssl x509 -in ca.crt -noout -dates`

**Expired Icarust certificates:**

Regenerate:

```bash
cd /path/to/Icarust/static/tls_certs/

# CA (valid 10 years)
openssl req -x509 -newkey rsa:4096 -keyout ca.key -out ca.crt \
  -days 3650 -nodes -subj "/CN=IcarustCA"

# Server key + CSR
openssl req -newkey rsa:4096 -keyout server.key -out server.csr \
  -nodes -subj "/CN=localhost"

# SAN extension
cat > ext.cnf <<EOF
[v3_req]
subjectAltName = DNS:localhost, IP:127.0.0.1
EOF

# Sign (valid 10 years)
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -out server.crt -days 3650 \
  -extfile ext.cnf -extensions v3_req

rm -f server.csr ext.cnf ca.srl
```

### Mapping Issues

**0% mapping rate:**

1. **Preset/model mismatch**: The preset (`-x`), pore model (`-p`), and `--r10` flag must match between indexing and live mapping.
2. **Signal format**: Use `--live-debug` to inspect raw signal ranges. ADC values (~0-10000) indicate int16; pA values (~50-150) indicate float32.
3. **Wrong calibration mode**: If using `--live-uncalibrated` with a calibrated server (or vice versa), the signal will be misinterpreted.

**All reads unmapped after max chunks:**

Increase `--max-num-chunk` (default 5) to allow more chunks before giving up. Alternatively, increase chunk size (`-c 8000`) to send more signal per chunk.

### Icarust Issues

**InvalidProbability crash:**

```
thread 'main' panicked at 'InvalidProbability'
```

Increase `target_yield` in the simulation TOML. The constraint is:

```
target_yield > global_mean_read_length * channels
```

With channels=3000 and mean_read_length=8000: use `target_yield = 100000000`.

**Hanging on shutdown:**

gRPC stream finalization can take ~10 seconds. If stuck longer, kill Icarust first (`pkill icarust`), then Ctrl+C RawHash2.

---

## Icarust Configuration Reference

Edit `live/example_config.toml` to customize simulation behavior:

```toml
output_path = "/tmp/icarust_test/"
target_yield = 100000000          # Must be > mean_read_length * channels
global_mean_read_length = 8000
pore_type = "R10"                 # "R10" or "R9" (must match index)
nucleotide_type = "DNA"
random_seed = 42

[parameters]
sample_rate = 4000                # 4 kHz standard
sequencing_speed = 400            # bases/sec (realistic: 200-500)
experiment_duration_set = 60      # seconds

[[sample]]
name = "E_coli_CFT073"
input_genome = "/absolute/path/to/ref.fa"   # MUST be absolute
mean_read_length = 8000
weight = 1                        # probability weight
```

Icarust also needs a `config.ini`:

```ini
[TLS]
cert-dir = /path/to/Icarust/static/tls_certs/

[PORTS]
manager = 10000
position = 10001

[SEQUENCER]
channels = 512
```

Key constraints:
- `input_genome` must be an **absolute path**
- `target_yield` must exceed `global_mean_read_length * channels` (from config.ini)
- `pore_type` must match the pore model used for indexing
- Icarust must be run from its own directory (to find `static/` kmer models)

---

## Automated Test Script

The convenience script `live/test_live.sh` automates the full Icarust workflow:

```bash
bash live/test_live.sh
```

Customize via environment variables:

```bash
ICARUST_DIR=/path/to/Icarust LIVE_DURATION=60 CHANNELS=512 bash live/test_live.sh
```

The script builds RawHash2, creates an R10 index, starts Icarust, runs live mapping, and reports results.

---

## Comparing Live vs. File-Based Mapping

**Offline baseline (file-based):**

```bash
bin/rawhash2 -x sensitive --r10 \
  -p extern/local_kmer_models/uncalled_r1041_model_only_means.txt \
  -d ref.idx -t 16 ref.fa reads.pod5 > offline.paf
```

**Live (streaming):**

```bash
bin/rawhash2 --live --live-port 10111 \
  --live-uncalibrated --live-no-sig-filter \
  -x sensitive --r10 -t 16 ref.idx > live.paf
```

Both produce PAF output. Key differences:
- **Offline**: processes entire reads at once, one-pass file scan
- **Live**: processes each chunk as it arrives, can make early mapping decisions mid-read, sends unblock decisions back through gRPC

For deterministic comparison, use the pod5 replay server with `--live-no-sig-filter` (disables the pA filter that the offline pipeline doesn't apply in the same way).

---

## Support

- GitHub Issues: https://github.com/STORMgroup/RawHash2/issues
- Include: OS, gRPC version (`protoc --version`), RawHash2 build log, and error output
