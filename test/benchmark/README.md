# RawHash2 Benchmark Test Bench

A self-contained set of scripts for quickly building and evaluating small
datasets with RawHash2. The goal is to let you iterate on parameters, pore
models, or code changes without waiting for full-scale runs.

---

## Contents

```
benchmark/
├── README.md          ← this file
└── scripts/
    ├── 1_fast5_to_pod5.sh         Convert fast5 → pod5
    ├── 2_create_small_pod5.sh     Subset pod5 to N reads
    ├── 3_run_dorado.sh            Basecall with Dorado (GPU or CPU)
    ├── 4_run_minimap2.sh          Generate ground-truth PAF with minimap2
    ├── 5_run_rawhash2_baseline.sh  v0 baseline: index + map + evaluate vs minimap2
    ├── 6_run_rawhash2_eval.sh     Iterative run: index + map + compare vs any PAF
    └── 6.1_run_rawhash2_eval_noindex.sh  Same as 6, but skips indexing (reuses pre-built .ind)
```

Each script is self-contained and accepts all paths as arguments — no
hard-coded paths, no assumed working directory.

---

## Prerequisites

The following tools must be available on your PATH. The recommended way is a
conda environment with the required packages installed.

| Tool       | Purpose                          | Min version |
|------------|----------------------------------|-------------|
| `pod5`     | Scripts 1 and 2 (POD5 I/O)      | 0.3         |
| `dorado`   | Script 3 (basecalling)           | 0.9.2       |
| `samtools` | Script 3 (BAM → FASTA)          | 1.10        |
| `minimap2` | Script 4 (ground-truth mapping)  | 2.24        |
| `rawhash2` | Scripts 5, 6, and 6.1 (signal mapping) | 2.0         |
| `python3`  | Scripts 5, 6, and 6.1 (evaluation)     | 3.6         |
| `numpy`    | Scripts 5, 6, and 6.1 (pafstats.py)    | any         |

### Quick install (conda)

```bash
conda create -n rawhash2-env python=3.9
conda activate rawhash2-env
conda install -c bioconda -c conda-forge minimap2 samtools pod5
```

> **Note:** `dorado` and `rawhash2` must be installed separately (see their
> respective repositories). Make sure they are on your PATH before running
> these scripts, or pass their paths explicitly via the `-b` flag.

---

## Typical Workflow

The full pipeline has six steps. Steps 1 and 2 are only needed if you do not
already have a small POD5 dataset. Steps 3 and 4 are one-time setup per
dataset (basecalling and ground-truth generation). Steps 5 and 6/6.1 are the
RawHash2-specific steps you will run repeatedly.

```
           ┌────────────────────────────────────────────────────────────┐
           │  One-time data preparation (steps 1–4)                     │
           │                                                             │
           │  fast5_files/  ──[step 1]──▶  pod5_files/                 │
           │  pod5_files/   ──[step 2]──▶  small_pod5_files/            │
           │  small_pod5_files/  ──[step 3]──▶  reads.bam + reads.fasta │
           │  reads.fasta + ref.fa  ──[step 4]──▶  true_mappings.paf    │
           └────────────────────────────────────────────────────────────┘

           ┌────────────────────────────────────────────────────────────┐
           │  RawHash2 evaluation loop (steps 5–6)                      │
           │                                                             │
           │  small_pod5_files/ + ref.fa + pore + true_mappings.paf     │
           │    ──[step 5]──▶  v0_baseline/  (index + paf + .results)   │
           │                                                             │
           │  Change params, re-run:                                     │
           │    ──[step 6]──▶   eval_*/  (rebuild index + map + eval)   │
           │    ──[step 6.1]──▶ eval_*/  (reuse index + map + eval)    │
           │      (compare against minimap2 PAF or v0 baseline PAF)     │
           └────────────────────────────────────────────────────────────┘
```

---

## Step-by-Step Examples

The examples below use E. coli R10.4.1 data as an example.
For R9.4.1, see [R9.4.1 Example](#r941-example-ecoli).

> **All paths below are placeholders.** Replace them with your actual paths.
> The scripts work from any directory when given absolute paths.

### Example variable setup

```bash
# Adjust these to match your installation
RH2=/path/to/rawhash2
DORADO=/path/to/dorado-1.4.0/bin/dorado
PORE_R10=/path/to/rawhash2/extern/local_kmer_models/uncalled_r1041_model_only_means.txt

DATA=/path/to/your/data
SCRIPTS=/path/to/rawhash2/test/benchmark/scripts
```

---

### Step 1 — Convert FAST5 to POD5 *(skip if already have .pod5 files)*

Only needed if your data is in FAST5 format. If you already have a pod5_files/
directory, skip to Step 2.

```bash
bash ${SCRIPTS}/1_fast5_to_pod5.sh \
  -i /path/to/fast5_files \
  -t 8
# Default output: /path/to/pod5_files/ (mirrored structure)
# Use -o /path/to/pod5_files to specify the output location explicitly.
```

**What it does:** Runs `pod5 convert fast5 -r --output-one-to-one` on all fast5 files,
mirroring the input directory structure — one `.pod5` file is created per `.fast5` file.

---

### Step 2 — Create a small POD5 subset

Extract the first N reads from the full dataset. This avoids waiting for hours
on full-scale runs during development.

```bash
bash ${SCRIPTS}/2_create_small_pod5.sh \
  -i ${DATA}/pod5_files \
  -n 5000 \
  -t 4
# Default output: ${DATA}/small_pod5_files/small.pod5

# To specify output directory and read count:
bash ${SCRIPTS}/2_create_small_pod5.sh \
  -i ${DATA}/pod5_files \
  -o ${DATA}/small_pod5_files \
  -n 2000 \
  -t 4
```

**What it does:** Lists all read IDs with `pod5 view --ids`, takes the first
`-n` of them, and creates a single `small.pod5` file via `pod5 filter`.

If the input has fewer reads than requested, all reads are used and a notice
is printed.

---

### Step 3 — Basecall with Dorado

Basecall the small POD5 to get FASTA reads. Run on a GPU for realistic output
quality and speed.

**R10.4.1 chemistry (dorado 1.4.0):**
```bash
bash ${SCRIPTS}/3_run_dorado.sh \
  -b ${DORADO} \
  -m hac \
  -i ${DATA}/small_pod5_files \
  -o ${DATA}/dorado_small \
  -t 16
```

**R9.4.1 chemistry (dorado 0.9.2):**
```bash
bash ${SCRIPTS}/3_run_dorado.sh \
  -b /path/to/dorado-0.9.2/bin/dorado \
  -m dna_r9.4.1_e8_hac@v3.3 \
  -i ${DATA}/small_pod5_files \
  -o ${DATA}/dorado_small \
  -t 16
```

> **CPU mode:** Add `-x cpu` to force CPU basecalling (slower; useful if no GPU available).

**Output:** `reads.bam`, `reads.fasta`, `basecall.time` in the output directory.

---

### Step 4 — Generate ground-truth PAF with minimap2

Map the basecalled reads to the reference. This is the "true answer" used to
score RawHash2 accuracy in steps 5 and 6.

```bash
bash ${SCRIPTS}/4_run_minimap2.sh \
  -i ${DATA}/dorado_small/reads.fasta \
  -r ${DATA}/ref.fa \
  -o ${DATA}/minimap2_small \
  -t 8
```

**Output:** `true_mappings.paf` and `minimap2.time` in the output directory.

---

### Step 5 — Establish v0 baseline with RawHash2

Run RawHash2 with default parameters and evaluate against the minimap2 ground
truth. This is your reference point for all subsequent comparisons.

**R10.4.1:**
```bash
bash ${SCRIPTS}/5_run_rawhash2_baseline.sh \
  -b ${RH2} \
  -i ${DATA}/small_pod5_files \
  -r ${DATA}/ref.fa \
  -p ${PORE_R10} \
  -g ${DATA}/minimap2_small/true_mappings.paf \
  -o ${DATA}/v0_baseline \
  --r10 -t 8
```

**R9.4.1:**
```bash
bash ${SCRIPTS}/5_run_rawhash2_baseline.sh \
  -b ${RH2} \
  -i ${DATA}/small_pod5_files \
  -r ${DATA}/ref.fa \
  -p /path/to/rawhash2/extern/kmer_models/legacy/legacy_r9.4_180mv_450bps_6mer/template_median68pA.model \
  -g ${DATA}/minimap2_small/true_mappings.paf \
  -o ${DATA}/v0_baseline \
  -t 8
```

**What it does (4 steps):**
1. Indexes the reference genome with rawhash2
2. Maps raw signals from the POD5 directory to the index
3. Annotates the PAF with TP/FP/FN/TN labels (via `pafstats.py`)
4. Computes detailed accuracy and throughput metrics (via `analyze_paf.py`)

**Output:** see [Output Files Reference](#output-files-reference).

**Example results file snippet:**
```
RawHash2 Baseline Results — rawhash2_baseline
==================================================

Run parameters:
  preset     : sensitive
  threads    : 8
  chemistry  : R10.4.1
  extra      : --r10

--- Throughput and Confusion Matrix ---
Summary: 5000 reads, 3145 mapped (62.90%)

Comparing to reference PAF
     P     N
T  54.50 16.21
F   2.08 24.32
NA: 2.89

Speed            Mean    Median
BP per sec: 117499.87 114262.36
...

--- Accuracy Metrics ---
RawHash2 precision: 0.9164
RawHash2 recall: 0.6914
RawHash2 F-1 score: 0.7882
...
```

---

### Step 6 — Iterative evaluation

Test a parameter change and compare against the minimap2 ground truth or the
v0 baseline rawhash2 PAF.

**Example A — test minimizer window -w 3 vs minimap2 ground truth:**
```bash
bash ${SCRIPTS}/6_run_rawhash2_eval.sh \
  -b ${RH2} \
  -i ${DATA}/small_pod5_files \
  -r ${DATA}/ref.fa \
  -p ${PORE_R10} \
  -g ${DATA}/minimap2_small/true_mappings.paf \
  -o ${DATA}/eval_w3 \
  --r10 -e "-w 3" -n rawhash2_w3 -t 8
```

> **Comparing against baseline:** Use `-g ${DATA}/v0_baseline/rawhash2_baseline.paf` instead of the minimap2 PAF to see which reads are classified differently relative to your v0 baseline.

**Example B — test a different preset (viral):**
```bash
bash ${SCRIPTS}/6_run_rawhash2_eval.sh \
  -b ${RH2} \
  -i ${DATA}/small_pod5_files \
  -r ${DATA}/ref.fa \
  -p ${PORE_R10} \
  -g ${DATA}/minimap2_small/true_mappings.paf \
  -o ${DATA}/eval_viral \
  --r10 -x viral -n rawhash2_viral -t 8
```

---

### Step 6.1 — Iterative evaluation (reuse existing index)

Same as Step 6, but **skips the indexing step** and uses a pre-built `.ind` file
via the `-I` flag. Use this when your experiment only changes mapping, chaining,
or segmentation parameters — not indexing parameters.

**When to use 6.1 vs 6:**

| Change type | Script | Why |
|-------------|--------|-----|
| Mapping params (`--min-anchors`, `--min-score`, `--bw`, `--max-chunks`, ...) | **6.1** | Index unchanged |
| Segmentation params (`--seg-window-length*`, `--seg-threshold*`, ...) | **6.1** | Index unchanged |
| Device params (`--bp-per-sec`, `--sample-rate`, `--chunk-size`) | **6.1** | Index unchanged |
| External files (`--peaks-file`, `--events-file`, `--moves-file`) | **6.1** | Index unchanged |
| Indexing params (`-w`, `-k`, `-e`, `-q`, `--sig-diff`, `-x preset`, `--r10`) | **6** | Must rebuild index |
| Different pore model (`-p`) | **6** | Must rebuild index |

**Example A — test --min-anchors 5, reuse v0 baseline index:**
```bash
bash ${SCRIPTS}/6.1_run_rawhash2_eval_noindex.sh \
  -b ${RH2} \
  -i ${DATA}/small_pod5_files \
  -I ${DATA}/v0_baseline/rawhash2_baseline.ind \
  -g ${DATA}/minimap2_small/true_mappings.paf \
  -o ${DATA}/eval_min_anchors_5 \
  -x sensitive --r10 \
  -e "--min-anchors 5" -n rawhash2_min_anchors_5 -t 8
```

**Example B — same experiment compared against v0 baseline PAF:**
```bash
bash ${SCRIPTS}/6.1_run_rawhash2_eval_noindex.sh \
  -b ${RH2} \
  -i ${DATA}/small_pod5_files \
  -I ${DATA}/v0_baseline/rawhash2_baseline.ind \
  -g ${DATA}/v0_baseline/rawhash2_baseline.paf \
  -o ${DATA}/eval_min_anchors_5_vs_v0 \
  -x sensitive --r10 \
  -e "--min-anchors 5" -n rawhash2_min_anchors_5_vs_v0 -t 8
```

> **Note:** The `-x` preset and `--r10` flag passed to script 6.1 must match
> what was used when building the index. They are needed for the mapping step
> but do not trigger re-indexing.

---

## R9.4.1 Example (E. coli)

```bash
DATA_D2=/path/to/your/r94/data
DORADO_R9=/path/to/dorado-0.9.2/bin/dorado
PORE_R9=/path/to/rawhash2/extern/kmer_models/legacy/legacy_r9.4_180mv_450bps_6mer/template_median68pA.model

bash ${SCRIPTS}/2_create_small_pod5.sh -i ${DATA_D2}/pod5_files -n 4000
bash ${SCRIPTS}/3_run_dorado.sh -b ${DORADO_R9} -m dna_r9.4.1_e8_hac@v3.3 -i ${DATA_D2}/small_pod5_files -o ${DATA_D2}/dorado_small -t 16
bash ${SCRIPTS}/4_run_minimap2.sh -i ${DATA_D2}/dorado_small/reads.fasta -r ${DATA_D2}/ref.fa -o ${DATA_D2}/minimap2_small -t 8
bash ${SCRIPTS}/5_run_rawhash2_baseline.sh -b ${RH2} -i ${DATA_D2}/small_pod5_files -r ${DATA_D2}/ref.fa -p ${PORE_R9} -g ${DATA_D2}/minimap2_small/true_mappings.paf -o ${DATA_D2}/v0_baseline -t 8
```

> **Note:** Omit `--r10` for R9.4.1 data. Use dorado 0.9.2 with explicit model `dna_r9.4.1_e8_hac@v3.3`.

---

## Script Reference

| Script | Purpose | Key inputs | Key outputs |
|--------|---------|-----------|-------------|
| `1_fast5_to_pod5.sh` | Convert fast5 to pod5 | `-i fast5_dir` | `pod5_files/` (mirrored structure) |
| `2_create_small_pod5.sh` | Subset N reads | `-i pod5_dir -n N` | `small_pod5_files/small.pod5` |
| `3_run_dorado.sh` | Basecall signals | `-b dorado -m model -i pod5 -o out` | `reads.bam reads.fasta basecall.time` |
| `4_run_minimap2.sh` | Ground-truth mapping | `-i reads.fasta -r ref.fa -o out` | `true_mappings.paf minimap2.time` |
| `5_run_rawhash2_baseline.sh` | v0 baseline run | `-b rh2 -i pod5 -r ref -p pore -g gt_paf -o out` | `*.paf *_ann.paf *.results` |
| `6_run_rawhash2_eval.sh` | Iterative evaluation (rebuild index) | `-b rh2 -i pod5 -r ref -p pore -g any_paf -o out` | `*.ind *.paf *_ann.paf *.results` |
| `6.1_run_rawhash2_eval_noindex.sh` | Iterative evaluation (reuse index) | `-b rh2 -i pod5 -I index.ind -g any_paf -o out` | `*.paf *_ann.paf *.results` |

Run any script with `-h` for full usage information:
```bash
bash scripts/5_run_rawhash2_baseline.sh -h
```

---

## Chemistry Guide

| Chemistry | Dorado version | Dorado model | RawHash2 pore model | RawHash2 flag |
|-----------|---------------|--------------|---------------------|---------------|
| R9.4.1    | 0.9.2         | `dna_r9.4.1_e8_hac@v3.3` | `extern/kmer_models/legacy/legacy_r9.4_180mv_450bps_6mer/template_median68pA.model` | *(none)* |
| R10.4.1   | 1.4.0         | `hac` (auto-selects latest model) | `extern/local_kmer_models/uncalled_r1041_model_only_means.txt` | `--r10` |

> **Note:** Dorado 0.9.2 is used for R9.4.1 and 1.4.0 for R10.4.1. With Dorado 0.9.2+,
> models are referenced by name and auto-downloaded on first use rather than requiring
> a local model path.

---

## Output Files Reference

Scripts 5, 6, and 6.1 produce these output files (PREFIX defaults to
`rawhash2_baseline` or `rawhash2_eval`):

| File | Description |
|------|-------------|
| `PREFIX.ind` | RawHash2 binary index — scripts 5 and 6 only (not produced by 6.1) |
| `PREFIX.paf` | Raw mapping output in PAF format |
| `PREFIX_ann.paf` | PAF annotated with `rf:Z:tp/fp/fn/tn/na` accuracy labels |
| `PREFIX.throughput` | Confusion matrix rows + BP/sec speed summary |
| `PREFIX.comparison` | Detailed per-class stats: precision, recall, F1, timing |
| `PREFIX_index.time` | Full `/usr/bin/time -v` output for the indexing step (scripts 5 and 6 only) |
| `PREFIX_map.time` | Full `/usr/bin/time -v` output for the mapping step |
| `PREFIX_index.out/err` | stdout/stderr from rawhash2 indexing (scripts 5 and 6 only) |
| `PREFIX_map.out/err` | stdout/stderr from rawhash2 mapping |
| `PREFIX.results` | Combined file: all of the above in one place |

### Annotation labels in `_ann.paf`

Each mapped/unmapped line gets a `rf:Z:LABEL` tag appended:

| Label | Meaning |
|-------|---------|
| `tp` | True Positive — mapped correctly (overlaps reference position) |
| `fp` | False Positive — mapped but to wrong location |
| `fn` | False Negative — unmapped but should have been |
| `tn` | True Negative — correctly unmapped (not in reference) |
| `na` | Mapped by rawhash2 but this read is unmapped in the reference PAF |

### `.time` file format

Generated by `/usr/bin/time -v`. Key lines:

```
Elapsed (wall clock) time (h:mm:ss or m:ss): 0:21.06
Maximum resident set size (kbytes): 2176088     # ÷ 1000000 = GB
User time (seconds): 98.00
System time (seconds): 11.27
```

---

## Notes

- All scripts are designed to run from any working directory (use absolute paths).
- The `--r10` flag must be passed for R10.4.1 data in scripts 5, 6, and 6.1. For
  R9.4.1 data, omit it.
- Scripts 1 and 2 require `pod5` on your PATH. Activate your conda environment
  before running, or install pod5 via `conda install -c conda-forge pod5`.
- Script 3 requires `samtools` on your PATH.
- Scripts 5, 6, and 6.1 automatically find `pafstats.py` and `analyze_paf.py` at
  `../../scripts/` relative to the benchmark scripts directory (i.e., `test/scripts/`).
- The `-e` flag in scripts 5/6/6.1 accepts any extra rawhash2 parameters as a quoted
  string, e.g. `-e "-w 3 --min-anchors 3"`.
- Script 6.1 is the preferred choice for most iterative experiments since it avoids
  redundant re-indexing. Only use script 6 when changing indexing-related parameters
  (`-w`, `-k`, `-e events`, `-q`, `--sig-diff`, preset, `--r10`, or pore model).
