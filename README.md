<p align="center" width="100%">
    <img width="65%" src="./gitfigures/rawhash-preview.png">
</p>

<p align="center" width="100%">
    <img width="75%" src="./gitfigures/rawsamble.png">
</p>

# RawHash2 Overview

RawHash2 is a hash-based mechanism to map raw nanopore signals to a reference genome in real-time. To achieve this, it 1) generates an index from the reference genome and 2) efficiently and accurately maps the raw signals to the reference genome such that it can match the throughput of nanopore sequencing even when analyzing large genomes (e.g., human genome.

Rawsamble is a mechanism that finds overlaps betweel raw signals without a reference genome (all-vs-all overlapping). The overlap information is generated in a PAF output and can be used by assemblers such as `miniasm` to construct *de novo* assemblies.

Below figure shows the overview of the steps that RawHash2 takes to find matching regions between a reference genome and a raw nanopore signal.

<p align="center" width="100%">
    <img width="50%" src="./gitfigures/overview.png">
</p>

To efficiently identify similarities between a reference genome and reads, RawHash has two steps, similar to regular read mapping tools, 1) indexing and 2) mapping. The indexing step generates hash values from the expected signal representation of a reference genome and stores them in a hash table. In the mapping step, RawHash generates the hash values from raw signals and queries the hash table generated in the indexing step to find seed matches. To map the raw signal to a reference genome, RawHash performs chaining over the seed matches.

RawHash2 can be used to map reads from **FAST5, POD5, SLOW5, or BLOW5** files to a reference genome in sequence format. **POD5 is the recommended format** as it is the current default for Oxford Nanopore sequencers.

RawHash performs real-time mapping of nanopore raw signals. When the prefix of reads can be mapped to a reference genome, RawHash will stop mapping and provide the mapping information in PAF format. We follow the similar PAF template used in [UNCALLED](https://github.com/skovaka/UNCALLED) and [Sigmap](https://github.com/haowenz/sigmap) to report the mapping information.

# Recent changes

* We have integrated **MinKNOW gRPC real-time signal streaming support (BETA)** for live selective sequencing workflows. This feature enables RawHash2 to receive signals directly from MinKNOW or the Icarust simulator and provide real-time mapping decisions. Currently tested and validated with the Icarust simulator. For detailed setup, installation, and testing instructions, see [docs/LIVE.md](docs/LIVE.md).

* We have integrated a new overlapping mechanism along with its presets, for our new mechanism, called **Rawsamble**. Please see below the corresponding section to run Rawsamble (i.e., overlapping) with RawHash.

* We came up with a better and more accurate quantization mechanism in RawHash2. The new quantization mechanism dynamically arranges the bucket sizes that each signal value is quantized depending on the normalized distribution of the signal values. **This provides significant improvements in both accuracy and performance.**

* We have integrated the signal alignment functionality with DTW as proposed in RawAlign (see the citation below). The parameters may still not be highly optimized as this is still in experimental stage. Use it with caution.

* All RawHash source code is now written in C. When compiling with POD5 or HDF5, sources are compiled as C++ to satisfy the requirements of those external libraries.

* We have released RawHash2, a more sensitive and faster raw signal mapping mechanism with substantial improvements over RawHash. RawHash2 is available within this repository. You can still use the earlier version, RawHash v1, from [this release](https://github.com/CMU-SAFARI/RawHash/releases/tag/v1.0).

* It is now possible to disable compiling HDF5, SLOW5, and POD5. Please check the `Compiling with HDF5, SLOW5, and POD5` section below for details.

# Installation

## Prerequisites

| Requirement | Linux | macOS |
|---|---|---|
| C++ compiler | GCC 11+ (`g++` 11 or later) | Xcode Command Line Tools (Apple Clang) |
| CMake | 3.16+ (for CMake build only) | 3.16+ (for CMake build only) |
| GNU Make | Required | Required |

> **Note:** When POD5 support is enabled (the default), all source files are compiled as C++ and linked against POD5 v0.3.36's pre-built static libraries. These libraries require GCC 11 or later on Linux. GCC 8.x is known to fail at link time. If you cannot upgrade GCC, you can disable POD5 with `make NOPOD5=1` to compile with any C99-compatible compiler, but POD5 signal input will not be available.

## Quick Start

* Clone the code from its GitHub repository (`--recursive` must be used):

```bash
git clone --recursive https://github.com/STORMgroup/RawHash2.git rawhash2
cd rawhash2
```

* **Recommended: Build with CMake** (see [Prerequisites](#prerequisites) above):

```bash
make cmake
```

* **Alternative: Build with Make only** (no CMake required, see [Prerequisites](#prerequisites)):

```bash
make
```

Both methods produce the binary at `bin/rawhash2`. By default, RawHash2 compiles with **POD5 support only**. To enable HDF5/FAST5 or SLOW5/BLOW5 support, see the section below.

## Compiling with HDF5, SLOW5, and POD5

RawHash2 provides two build systems. The recommended approach is CMake, which provides the most flexibility. The standalone Makefile is an alternative for systems without CMake.

### Using CMake (Recommended)

**Default build** (POD5 only):

```bash
make cmake
```

**Enable additional formats:**

```bash
# Enable all three formats (HDF5, SLOW5, POD5)
make cmake CMAKE_OPTS="-DENABLE_HDF5=ON -DENABLE_SLOW5=ON"

# Enable only HDF5 and POD5
make cmake CMAKE_OPTS="-DENABLE_HDF5=ON"

# Enable only SLOW5 and POD5
make cmake CMAKE_OPTS="-DENABLE_SLOW5=ON"

# Disable POD5, enable HDF5 and SLOW5
make cmake CMAKE_OPTS="-DENABLE_HDF5=ON -DENABLE_SLOW5=ON -DENABLE_POD5=OFF"
```

**Debug, profiling, and sanitizer builds:**

```bash
# Debug build with debug symbols (-O2 -g)
make cmake CMAKE_OPTS="-DCMAKE_BUILD_TYPE=Debug"

# Enable profiling (-g -fno-omit-frame-pointer -DPROFILERH=1)
make cmake CMAKE_OPTS="-DENABLE_PROFILING=ON"

# Enable AddressSanitizer
make cmake CMAKE_OPTS="-DENABLE_ASAN=ON"

# Enable ThreadSanitizer
make cmake CMAKE_OPTS="-DENABLE_TSAN=ON"

# Combine options
make cmake CMAKE_OPTS="-DCMAKE_BUILD_TYPE=Debug -DENABLE_ASAN=ON -DENABLE_HDF5=ON"
```

**Or invoke CMake directly** for full control:

```bash
mkdir build && cd build
cmake -DENABLE_HDF5=ON -DENABLE_SLOW5=ON ..
cmake --build . -j4
cp src/rawhash2 ../bin/
```

**Use system-installed HDF5** instead of building from submodule:

```bash
make cmake CMAKE_OPTS="-DENABLE_HDF5=ON -DUSE_SYSTEM_HDF5=ON"
```

### Using Make (No CMake Required)

**Default build** (POD5 only):

```bash
make
```

**Disable/enable formats:**

```bash
# Disable POD5 (compile with no external signal format libraries)
make NOPOD5=1

# Enable HDF5 along with POD5
make NOHDF5=0

# Enable SLOW5 along with POD5
make NOSLOW5=0

# Enable all formats
make NOHDF5=0 NOSLOW5=0
```

**Debug, profiling, and sanitizer builds:**

```bash
# Debug build with AddressSanitizer (-O2 -fsanitize=address -g)
make DEBUG=1

# Enable profiling (-g -fno-omit-frame-pointer -DPROFILERH=1)
make PROFILE=1

# Enable AddressSanitizer without full debug mode
make asan=1

# Enable ThreadSanitizer
make tsan=1

# Combine options
make DEBUG=1 NOHDF5=0
```

**Rebuild without recompiling external dependencies:**

```bash
make subset
```

## gRPC Live Streaming Support (MinKNOW/Icarust) — BETA

RawHash2 now supports **real-time signal streaming** from Oxford Nanopore's MinKNOW software or the Icarust simulator. This enables live selective sequencing workflows where mapping decisions are made in real-time.

**Status:** Beta version, tested with Icarust simulator. Real MinKNOW integration ready but not yet tested on physical hardware.

**Building with gRPC support:**

```bash
# CMake (Recommended)
make cmake CMAKE_OPTS="-DENABLE_GRPC=ON"

# With additional format support
make cmake CMAKE_OPTS="-DENABLE_GRPC=ON -DENABLE_HDF5=ON -DENABLE_SLOW5=ON"
```

**Prerequisites for gRPC:**

| Platform | Requirement |
|----------|-------------|
| macOS | `brew install grpc` |
| Linux | `conda create -n rawhash2-live grpcio grpcio-tools libgrpc protobuf cmake` |

**Quick test (requires Icarust simulator):**

```bash
# Terminal 1: Start Icarust
export HDF5_DIR=$(brew --prefix hdf5@1.10)  # macOS
./Icarust/target/release/icarust docs/live/example_config.toml

# Terminal 2: Run RawHash2 live
bin/rawhash2 --live --live-port 10001 -t 4 ref.idx > live_output.paf
```

For comprehensive setup, testing, and troubleshooting instructions, see **[docs/LIVE.md](docs/LIVE.md)**.

# Usage

## Getting help

You can print the help message to learn how to use `rawhash2`:

```bash
rawhash2
```

or 

```bash
rawhash2 -h
```

## Indexing
Indexing is similar to minimap2's usage. We additionally include the pore models located under ./extern

Below is an example that generates an index file `ref.ind` for the reference genome `ref.fasta` using a certain k-mer model located under `extern` and `32` threads.

* R9.4 indexing:

```bash
rawhash2 -d ref.ind -p extern/kmer_models/legacy/legacy_r9.4_180mv_450bps_6mer/template_median68pA.model -t 32 ref.fasta
```

* R10.4.1 indexing (uses a different pore model and the `--r10` flag):

```bash
rawhash2 -d ref.ind -p extern/local_kmer_models/uncalled_r1041_model_only_means.txt --r10 -t 32 ref.fasta
```

Note that you can directly jump to mapping without creating the index because RawHash2 is able to generate the index relatively quickly on-the-fly within the mapping step. However, a real-time genome analysis application may still prefer generating the indexing before the mapping step. Thus, we suggest creating the index before the mapping step.

## Mapping

It is possible to provide inputs as FAST5 files from multiple directories. It is also possible to provide a list of files matching a certain pattern such as `test/data/contamination/fast5_files/Min*.fast5`

* Example usage where multiple files matching a certain the pattern `test/data/contamination/fast5_files/Min*.fast5` and fast5 files inside the `test/data/d1_sars-cov-2_r94/fast5_files` directory are inputted to rawhash2 using `32` threads and the previously generated `ref.ind` index:

```bash
rawhash2 -t 32 ref.ind test/data/contamination/fast5_files/Min*.fast5 test/data/d1_sars-cov-2_r94/fast5_files > mapping.paf
```

* Another example usage where 1) we only input a directory including FAST5 files as set of raw signals and 2) the output is directly saved in a file.

```bash
rawhash2 -t 32 -o mapping.paf ref.ind test/data/d1_sars-cov-2_r94/fast5_files
```

**IMPORTANT** if there are many fast5 files that rawhash2 needs to process (e.g., thousands of them), we suggest that you specify **only** the directories that contain these fast5 files

RawHash2 also provides a set of default parameters that can be preset automatically.

* Mapping reads to a viral reference genome using its corresponding preset:

```
rawhash2 -t 32 -x viral ref.ind test/data/d1_sars-cov-2_r94/fast5_files > mapping.paf
```

* Mapping reads to small reference genomes (<500M bases) using its corresponding preset:

```
rawhash2 -t 32 -x sensitive ref.ind test/data/d4_green_algae_r94/fast5_files > mapping.paf
```

* If you want to map a R10.4.1 dataset (or R10 in general), please insert the following preset along with other presets:

```
rawhash2 -t 32 -x sensitive --r10 ref.ind test/data/d6_ecoli_r104/fast5_files > mapping.paf
```

For indexing, please use the k-mer model generated by [UNCALLED4](./extern/local_kmer_models/uncalled_r1041_model_only_means.txt)

* Mapping reads to large reference genomes (>500M bases) using its corresponding preset:

```
rawhash2 -t 32 -x fast ref.ind test/data/d5_human_na12878_r94/fast5_files > mapping.paf
```

RawHash2 provides another set of default parameters that can be used for very large metagenomic samples (>10G). To achieve efficient search, it uses the minimizer seeding in this parameter setting, which is slightly less accurate than the non-minimizer mode but much faster (around 3X).

```
rawhash2 -t 32 -x faster ref.ind test/data/d5_human_na12878_r94/fast5_files > mapping.paf
```

The output will be saved to `mapping.paf` in a modified PAF format used by [Uncalled](https://github.com/skovaka/UNCALLED).

# Functionalities

RawHash2 provides several key functionalities beyond basic read mapping. This section describes each feature and how to enable it.

## R10.4.1 Support

RawHash2 supports R10.4.1 (and R10 in general) nanopore data. R10 uses 9-mer pore models (vs 6-mer for R9.4) and different device parameters (e.g., different sampling rate). Use the `--r10` flag along with the appropriate pore model.

**Indexing for R10.4.1:**

```bash
rawhash2 -d ref_r10.ind \
  -p extern/local_kmer_models/uncalled_r1041_model_only_means.txt \
  --r10 -t 32 ref.fasta
```

**Mapping for R10.4.1:**

```bash
rawhash2 -t 32 -x sensitive --r10 ref_r10.ind pod5_files/ > mapping.paf
```

## Signal Alignment (RawAlign)

RawHash2 integrates DTW-based signal alignment as proposed in [RawAlign](https://doi.org/10.1109/ACCESS.2024.3520669). This refines mapping accuracy by aligning the raw signal against the reference signal using Dynamic Time Warping.

To use signal alignment, the index must be built with `--store-sig` to store reference signal values:

```bash
# Build index with reference signal stored
rawhash2 -d ref.ind -p pore_model.txt --store-sig -t 32 ref.fasta

# Map with DTW-based chain evaluation and CIGAR output
rawhash2 -t 32 --dtw-evaluate-chains --dtw-output-cigar ref.ind pod5_files/ > mapping.paf
```

DTW options control the alignment behavior:
- `--dtw-border-constraint`: alignment scope (`global`, `sparse`, or `local`; default: `sparse`)
- `--dtw-fill-method`: matrix computation (`full` or `banded[=FRAC]`; default: `banded`)
- `--dtw-match-bonus`: match score bonus (default: 0.4)
- `--dtw-min-score`: minimum DTW score to report a mapping (default: 20.0)

## External Segmentation

By default, RawHash2 uses a built-in t-test peak detector to segment raw signal into events. You can instead provide pre-computed segmentation data using one of three mutually exclusive options:

### Peak Positions (`--peaks-file`)

Provide pre-computed peak positions (segment boundaries) in the raw signal.

File format (tab-separated):
```
read_id    peak1 peak2 peak3 ... peakN
```

### Event Values (`--events-file`)

Provide pre-computed event-level values (e.g., from an external segmentation tool).

File format (tab-separated):
```
read_id    ev1 ev2 ev3 ... evN
```

### Move Tables from Dorado (`--moves-file`)

Use move table data from [dorado](https://github.com/nanoporetech/dorado) basecaller output. The move table encodes which signal samples correspond to base transitions, enabling RawHash2 to use dorado's neural-network-based segmentation.

File format (tab-separated, one line per read):
```
read_id    mv:B:c,STRIDE,0,1,...    ts:i:OFFSET
```

**Extract move tables from a dorado BAM:**

```bash
# Use the provided helper script (requires samtools)
test/scripts/extract_moves_from_bam.sh reads_dorado.bam > moves.tsv

# Then map with dorado's segmentation
rawhash2 --moves-file moves.tsv -p pore_model.txt -d ref.ind ref.fasta pod5_files/
```

The `--min-seg-length` and `--max-seg-length` parameters control the minimum and maximum allowed segment lengths (in samples), regardless of which segmentation method is used. You may also consider setting `--sig-diff 0`, which is a heuristic that performs homopolymer compression to mitigate the oversegmentation issue in t-test. Similar strategy is used in Sigmap and Sigmoni tools as well.

## Sequence Until (Real-Time Abundance Estimation)

Sequence Until provides real-time abundance estimation during sequencing. It periodically estimates the composition of the sequenced sample and can be used to determine when sufficient data has been collected.

```bash
rawhash2 -t 32 --sequence-until ref.ind pod5_files/ > mapping.paf
```

Key parameters:
- `--threshold`: outlier distance threshold (default: 1.5)
- `--n-samples`: number of previous estimations to compare (default: 5)
- `--test-frequency`: re-estimate every N reads (default: 500)
- `--min-reads`: minimum reads before first estimate (default: 500)

## Contamination Analysis

The `--depletion` flag provides a high-precision mode suitable for contamination detection and abundance analysis. It adjusts internal parameters to prioritize precision over recall.

```bash
rawhash2 -t 32 -x sensitive --depletion ref.ind pod5_files/ > mapping.paf
```

## Rawsamble (for overlapping and assembly construction)

Our new overlapping mechanism, Rawsamble, is now integrated in RawHash2. To create overlaps, you can construct the index from signals and perform overlapping using this index as follows:

```
rawhash2 -x ava -p ../../rawhash2/extern/kmer_models/legacy/legacy_r9.4_180mv_450bps_6mer/template_median68pA.model -d ava.ind -t32 test/data/d3_yeast_r94/fast5_files/
```

Then perform overlapping using this index:

```
rawhash2 -x ava -t32 ava.ind test/data/d3_yeast_r94/fast5_files/ > ava.paf
```

We provide the following presets for Rawsamble to enable the overlapping mode (shown in the help message):


```bash
Rawsamble Presets:
                 - ava     	All-vs-all overlapping mode (default for Rawsamble)
                 - ava-sensitive     	More sensitive All-vs-all overlapping mode. Can be slightly slower than -ava but likely to generate longer unitigs in downstream asssembly
                 - ava-viral     	All-vs-all overlapping for very small genomes such as viral genomes.
                 - ava-large     	All-vs-all overlapping for large genomes of size > 10Gb
```

## Potential issues you may encounter during mapping

It is possible that your reads in fast5 files are compressed with the [VBZ compression](https://github.com/nanoporetech/vbz_compression) from Nanopore. Then you have to download the proper HDF5 plugin from [here](https://github.com/nanoporetech/vbz_compression/releases) and make sure it can be found by your HDF5 library:

```bash
export HDF5_PLUGIN_PATH=/path/to/hdf5/plugins/lib
```

If you have conda you can simply install the following package (`ont_vbz_hdf_plugin`) in your environment and use rawhash2 while the environment is active:

```bash
conda install ont_vbz_hdf_plugin
```
# Reproducing the results

Please follow the instructions in the [README](test/README.md) file in [test](./test/).

# Upcoming Features

* Direct integration with MinKNOW.
* Ability to specify even/odd channels to eject the reads only from these specified channels.
* Please create issues if you want to see more features that can make RawHash2 easily integratable with nanopore sequencers for any use case.

# Citing RawHash, RawHash2, Rawsamble, and RawAlign

If you use RawHash (or RawHash2) in your work, please consider citing the following papers:

```bibtex
@article{firtina_rawhash_2023,
	title = {{RawHash}: enabling fast and accurate real-time analysis of raw nanopore signals for large genomes},
	author = {Firtina, Can and Mansouri Ghiasi, Nika and Lindegger, Joel and Singh, Gagandeep and Cavlak, Meryem Banu and Mao, Haiyu and Mutlu, Onur},
	journal = {Bioinformatics},
	volume = {39},
	number = {Supplement_1},
	pages = {i297-i307},
	month = jun,
	year = {2023},
	doi = {10.1093/bioinformatics/btad272},
	issn = {1367-4811},
	url = {https://doi.org/10.1093/bioinformatics/btad272},
}

@article{firtina_rawhash2_2024,
	title = {{RawHash2}: mapping raw nanopore signals using hash-based seeding and adaptive quantization},
	volume = {40},
	issn = {1367-4811},
	url = {https://doi.org/10.1093/bioinformatics/btae478},
	doi = {10.1093/bioinformatics/btae478},
	number = {8},
	journal = {Bioinformatics},
	author = {Firtina, Can and Soysal, Melina and Lindegger, Joël and Mutlu, Onur},
	month = aug,
	year = {2024},
	pages = {btae478},
}
```

If you use Rawsamble (i.e., all-vs-all overlapping functionality integrated in RawHash2) please consider citing the following work along with RawHash and RawHash2: 

```bibtex
@article{firtina_rawsamble_2024,
  title = {{Rawsamble: Overlapping and Assembling Raw Nanopore Signals using a Hash-based Seeding Mechanism}},
  author = {Firtina, Can and Mordig, Maximilian and Mustafa, Harun and Goswami, Sayan and Mansouri Ghiasi, Nika and Mercogliano, Stefano and Eris, Furkan and Lindegger, Joël and Kahles, Andre and Mutlu, Onur},
  journal = {arXiv},
  year = {2024},
  month = oct,
  doi = {10.48550/arXiv.2410.17801},
  url = {https://doi.org/10.48550/arXiv.2410.17801},
}
```

If you use RawAlign (i.e., the alignment functionality integrated in RawHash2) please consider citing the following work along with RawHash and RawHash2: 

```bibtex
@article{lindegger_rawalign_2024,
	title = {{RawAlign}: {Accurate, Fast, and Scalable Raw Nanopore Signal Mapping via Combining Seeding and Alignment}},
  	author = {Lindegger, Joël and Firtina, Can and Ghiasi, Nika Mansouri and Sadrosadati, Mohammad and Alser, Mohammed and Mutlu, Onur},
  	journal = {IEEE Access},
  	year = {2024},
	month = dec,
	doi = {10.1109/ACCESS.2024.3520669},
	url = {https://doi.org/10.1109/ACCESS.2024.3520669},
}
```

# Acknowledgement

RawHash2 uses [klib](https://github.com/attractivechaos/klib), some code snippets from [Minimap2](https://github.com/lh3/minimap2) (e.g., pipelining, hash table usage, DP and RMQ-based chaining) and the R9.4 segmentation parameters from [Sigmap](https://github.com/haowenz/sigmap). RawHash2 uses the DTW integration as proposed in RawAlign (please see the citation details above).