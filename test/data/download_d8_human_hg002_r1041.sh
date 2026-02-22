#!/bin/bash

mkdir -p d8_human_hg002_r1041/pod5_files/
cd d8_human_hg002_r1041/pod5_files

#Download POD5 from AWS ONT Open Data (GIAB HG002, R10.4.1)
aws s3 cp s3://ont-open-data/giab_2023.05/flowcells/hg002/20230424_1302_3H_PAO89685_2264ba8c/pod5_pass/ ./ --recursive --no-sign-request

cd ..;

# Optional: Basecall using dorado (R10.4.1 e8.2 chemistry, dorado 1.4.0).
# Chemistry: R10.4.1 e8.2, flowcell FLO-PRO114M (PromethION), sample rate 5kHz.
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
#TODO: Provide the direct link to download basecalled reads

#Downloading CHM13v2 (hs1) Human reference genome;
wget https://hgdownload.soe.ucsc.edu/goldenPath/hs1/bigZips/hs1.fa.gz; gunzip hs1.fa.gz; mv hs1.fa ref.fa

cd ..
