# RawHash2

Real-time, ultrafast, and lightweight raw nanopore signal mapping tool.

## Project Overview

RawHash2 maps raw Oxford Nanopore Technologies (ONT) electrical signals directly to a reference genome without basecalling. It also supports all-vs-all overlapping via the Rawsamble component.

**This is a command-line bioinformatics tool — no frontend or web server.**

## Architecture

- **Language**: C (C99) with C++11 for POD5/HDF5 support
- **Build systems**: GNU Make (primary) and CMake (alternative)
- **Entry point**: `src/main.c`
- **Output binary**: `bin/rawhash2`

## Components

- `src/rmap.c/h` - Mapping logic
- `src/rindex.c/h` - Indexing logic
- `src/rsig.c/h` - Signal processing
- `src/rlive.cpp/h` - MinKNOW gRPC integration (requires CMake + gRPC)
- `src/dtw.c/h` - Dynamic Time Warping alignment
- `extern/` - Third-party git submodules (zstd, slow5lib, hdf5, kmer_models)

## Building

The project is built with `bash build.sh` which calls the standalone Makefile without POD5/HDF5/SLOW5 support (those require git submodules and/or downloads).

```bash
bash build.sh
```

The build requires zlib (provided by Nix). It detects paths automatically via `$NIX_CFLAGS_COMPILE` and `$NIX_LDFLAGS`.

### Build options (via src/Makefile)
- `NOPOD5=1` - Disable POD5 support (enabled by default in build.sh)
- `NOHDF5=1` - Disable HDF5/FAST5 support
- `NOSLOW5=1` - Disable SLOW5/BLOW5 support
- `DEBUG=1` - Debug build with AddressSanitizer
- `PROFILE=1` - Profiling build

## Usage

```
./bin/rawhash2 [options] <target.fa>|<target.idx> [query.fast5|.pod5|.slow5] [...]
```

## Workflow

- **Build RawHash2** - Builds the rawhash2 binary (console output)

## Dependencies

- **zlib** - Installed via Nix system packages
- **Git submodules** (optional, not initialized):
  - `extern/zstd` - For POD5/SLOW5 support
  - `extern/slow5lib` - SLOW5/BLOW5 format support
  - `extern/hdf5` - HDF5/FAST5 format support
  - `extern/kmer_models` - Nanopore pore models
