#!/bin/bash

mkdir -p d10_dmelanogaster_r1041/fast5_files/
cd d10_dmelanogaster_r1041

#Download FAST5 from AWS ONT Open Data (D. melanogaster, R10.4.1)
#Source: https://labs.epi2me.io/open-data-dmelanogaster-bkim/
aws s3 cp s3://ont-open-data/contrib/melanogaster_bkim_2023.01/flowcells/D.melanogaster.R1041.400bps/D_melanogaster_1/20221217_1251_MN20261_FAV70669_117da01a/fast5/ ./fast5_files/ --recursive --no-sign-request

# Optional: Convert FAST5 to POD5 (recommended format for RawHash2 and benchmark pipeline).
# Requires: conda install -c conda-forge pod5
# Using the benchmark conversion script:
#   SCRIPTS=/path/to/rawhash2/test/benchmark/scripts
#   bash ${SCRIPTS}/1_fast5_to_pod5.sh -i ./fast5_files -o ./pod5_files -t 8
# Or directly:
#   pod5 convert fast5 -r --one-to-one ./fast5_files -t 8 -o ./pod5_files ./fast5_files

# Optional: Basecall using dorado (R10.4.1 e8.2 chemistry, dorado 0.9.2).
# Chemistry: R10.4.1 e8.2, flowcell FLO-MIN114 (MinION), sample rate 4kHz.
# Dorado version: 0.9.2.
# Model: dna_r10.4.1_e8.2_400bps_hac@v3.5.2 (specify as full filesystem path).
#   Note: dorado 1.4.0 with v5.2.0 model requires 5kHz data, so use dorado 0.9.2 with v3.5.2.
# Note: dorado 0.9.2 does NOT support --disable-read-splitting, so we pass
#       --enable-read-splitting to the benchmark script to skip that flag.
# Requires pod5_files/ (see conversion above) and a dorado binary.
# Using the benchmark basecalling script:
#   SCRIPTS=/path/to/rawhash2/test/benchmark/scripts
#   DORADO=/path/to/dorado-0.9.2-linux-x64
#   bash ${SCRIPTS}/3_run_dorado.sh \
#     -b ${DORADO}/bin/dorado \
#     -m ${DORADO}/bin/dna_r10.4.1_e8.2_400bps_hac@v3.5.2 \
#     -i ./pod5_files -o ./dorado-0.9.2 -t 16 \
#     --enable-read-splitting
# Output: dorado-0.9.2/reads.bam, dorado-0.9.2/reads.fasta
# Symlink so that evaluation scripts find reads.fasta at the dataset root:
#   ln -sf dorado-0.9.2/reads.fasta reads.fasta

#Downloading D. melanogaster Release 6 reference genome (dm6) from UCSC; Unzip; Change name;
wget https://hgdownload.soe.ucsc.edu/goldenPath/dm6/bigZips/dm6.fa.gz; gunzip dm6.fa.gz; mv dm6.fa ref.fa

cd ..
