#!/bin/bash

mkdir -p d7_saureus_r104/fast5_files/
cd d7_saureus_r104/fast5_files

#Download FAST5 from AWS | Unzip; NCBI SRA Link: https://trace.ncbi.nlm.nih.gov/Traces/?run=SRR21386013
wget -qO- https://sra-pub-src-1.s3.amazonaws.com/SRR21386013/S_aureus_JKD6159_ONT_R10.4_fast5.tar.gz.1 | tar xzv;

cd ..;

# Optional: Convert FAST5 to POD5 (recommended format for RawHash2 and benchmark pipeline).
# Requires: conda install -c conda-forge pod5
# Using the benchmark conversion script:
#   SCRIPTS=/path/to/rawhash2/test/benchmark/scripts
#   bash ${SCRIPTS}/1_fast5_to_pod5.sh -i ./fast5_files -o ./pod5_files -t 8
# Or directly:
#   pod5 convert fast5 -r --one-to-one ./fast5_files -t 8 -o ./pod5_files ./fast5_files

# Optional: Basecall using dorado (R10.4 e8.1 chemistry, dorado 0.9.2).
# Chemistry: R10.4 e8.1, flowcell FLO-MIN112, kit SQK-NBD112-96, sample rate 4kHz.
#   basecall_config_filename in fast5: dna_r10.4_e8.1_sup.cfg
# Dorado version: 0.9.2.
# Model: dna_r10.4.1_e8.2_400bps_hac@v4.1.0 (specify as full filesystem path).
# Note: dorado 0.9.2 does NOT support --disable-read-splitting, so we pass
#       --enable-read-splitting to the benchmark script to skip that flag.
# Requires pod5_files/ (see conversion above) and a dorado binary.
# Using the benchmark basecalling script:
#   SCRIPTS=/path/to/rawhash2/test/benchmark/scripts
#   DORADO=/path/to/dorado-0.9.2-linux-x64
#   bash ${SCRIPTS}/3_run_dorado.sh \
#     -b ${DORADO}/bin/dorado \
#     -m ${DORADO}/bin/dna_r10.4.1_e8.2_400bps_hac@v4.1.0 \
#     -i ./pod5_files -o ./dorado-0.9.2 -t 16 \
#     --enable-read-splitting
# Output: dorado-0.9.2/reads.bam, dorado-0.9.2/reads.fasta
# Symlink so that evaluation scripts find reads.fasta at the dataset root:
#   ln -sf dorado-0.9.2/reads.fasta reads.fasta
#TODO: Provide the direct link to download basecalled reads

#Downloading Staphylococcus aureus subsp. aureus JKD6159, complete genome; Unzip; Change name;
wget https://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/000/144/955/GCF_000144955.2_ASM14495v2/GCF_000144955.2_ASM14495v2_genomic.fna.gz; gunzip GCF_000144955.2_ASM14495v2_genomic.fna.gz; mv GCF_000144955.2_ASM14495v2_genomic.fna ref.fa

cd ..
