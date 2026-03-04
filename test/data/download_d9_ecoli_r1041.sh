#!/bin/bash

mkdir -p d9_ecoli_r1041/pod5_files/
cd d9_ecoli_r1041

#Download POD5 from AWS | Unzip; Mv POD5 files into the pod5_files directory. Link: https://github.com/mbhall88/NanoVarBench/blob/main/config/accessions.csv
wget -qO- https://figshare.unimelb.edu.au/ndownloader/files/45408628 | tar xvf -; mv ATCC_25922__202309/*.pod5 pod5_files; rm -rf ATCC_25922__202309
# mv 45408628 ATCC_25922__202309.tar

#Downloading Escherichia coli CFT073, complete genome (https://www.ncbi.nlm.nih.gov/nuccore/AE014075.1/); Unzip; Change name;
wget https://ftp.ncbi.nlm.nih.gov/genomes/all/GCA/000/007/445/GCA_000007445.1_ASM744v1/GCA_000007445.1_ASM744v1_genomic.fna.gz; gunzip GCA_000007445.1_ASM744v1_genomic.fna.gz; mv GCA_000007445.1_ASM744v1_genomic.fna ref.fa

# Optional: Basecall using dorado (R10.4.1 e8.2 chemistry, dorado 1.4.0).
# Chemistry: R10.4.1 e8.2, flowcell FLO-MIN114 (MinION), sample rate 5kHz.
# Dorado version: 1.4.0.
# Model: dna_r10.4.1_e8.2_400bps_hac@v5.2.0 (specify as full filesystem path).
# Read splitting is disabled by default in the benchmark script because R10.4.1
#   reads are mainly impacted by chimeric read splitting artifacts.
# Requires a dorado binary.
# Using the benchmark basecalling script:
#   SCRIPTS=/path/to/rawhash2/test/benchmark/scripts
#   DORADO=/path/to/dorado-1.4.0-linux-x64
#   bash ${SCRIPTS}/3_run_dorado.sh \
#     -b ${DORADO}/bin/dorado \
#     -m ${DORADO}/bin/dna_r10.4.1_e8.2_400bps_hac@v5.2.0 \
#     -i ./pod5_files -o ./dorado-1.4.0 -t 16
# Output: dorado-1.4.0/reads.bam, dorado-1.4.0/reads.fasta
# Symlink so that evaluation scripts find reads.fasta at the dataset root:
#   ln -sf dorado-1.4.0/reads.fasta reads.fasta
