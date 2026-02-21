#!/bin/bash

mkdir -p d4_green_algae_r94/fast5_files/
cd d4_green_algae_r94

#Download FAST5 from AWS
wget -qO- https://sra-pub-src-2.s3.amazonaws.com/ERR3237140/Chlamydomonas_0.tar.gz.1 | tar xzv;

find ./Chlamydomonas_0/reads/downloads/pass/ -type f -name '*.fast5' | xargs -i{} mv {} fast5_files/

awk 'BEGIN{line = 0}{line++; if(line %4 == 1){print ">"substr($1,2)}else if(line % 4 == 2){print $0}}' ./Chlamydomonas_0/reads/downloads/pass/*.fastq > reads.fasta

rm -rf Chlamydomonas_0

#Downloading C.reinhardtii v.5.5 reference genome
wget https://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/000/002/595/GCF_000002595.2_Chlamydomonas_reinhardtii_v5.5/GCF_000002595.2_Chlamydomonas_reinhardtii_v5.5_genomic.fna.gz; gunzip GCF_000002595.2_Chlamydomonas_reinhardtii_v5.5_genomic.fna.gz; mv GCF_000002595.2_Chlamydomonas_reinhardtii_v5.5_genomic.fna ref.fa

# Optional: Convert FAST5 to POD5 (recommended format for RawHash2 and benchmark pipeline).
# Requires: conda install -c conda-forge pod5
# Using the benchmark conversion script:
#   SCRIPTS=/path/to/rawhash2/test/benchmark/scripts
#   bash ${SCRIPTS}/1_fast5_to_pod5.sh -i ./fast5_files -o ./pod5_files -t 8
# Or directly:
#   pod5 convert fast5 -r --one-to-one ./fast5_files -t 8 -o ./pod5_files ./fast5_files

# Optional: Basecall using dorado (R9.4.1 chemistry, dorado 0.9.2).
# Requires pod5_files/ (see conversion above) and a dorado binary.
# Using the benchmark basecalling script:
#   bash ${SCRIPTS}/3_run_dorado.sh \
#     -b /path/to/dorado-0.9.2/bin/dorado \
#     -m dna_r9.4.1_e8_hac@v3.3 -i ./pod5_files -o ./dorado-0.9.2 -t 16
# Output: dorado-0.9.2/reads.bam, dorado-0.9.2/reads.fasta

cd ..
