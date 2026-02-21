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

#Basecall the signals using dorado (R10.4 chemistry, dorado 1.4.0).
# Requires pod5_files/ (see conversion above) and a dorado binary.
# Using the benchmark basecalling script:
#   bash ${SCRIPTS}/3_run_dorado.sh \
#     -b /path/to/dorado-1.4.0/bin/dorado \
#     -m hac -i ./pod5_files -o ./dorado-1.4.0 -t 16
# Output: dorado-1.4.0/reads.bam, dorado-1.4.0/reads.fasta
#TODO: Provide the direct link to download basecalled reads

#Downloading Staphylococcus aureus subsp. aureus JKD6159, complete genome; Unzip; Change name;
wget https://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/000/144/955/GCF_000144955.2_ASM14495v2/GCF_000144955.2_ASM14495v2_genomic.fna.gz; gunzip GCF_000144955.2_ASM14495v2_genomic.fna.gz; mv GCF_000144955.2_ASM14495v2_genomic.fna ref.fa

cd ..
