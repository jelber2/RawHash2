#!/bin/bash

mkdir -p d2_ecoli_r94/fast5_files/
cd d2_ecoli_r94

#Download FAST5 from AWS | Unzip; Mv FAST5 files into the fast5_files directory. NCBI SRA Link: https://trace.ncbi.nlm.nih.gov/Traces/?run=ERR9127551
wget -qO- https://sra-pub-src-2.s3.amazonaws.com/ERR9127551/ecoli_r9.tar.gz.1 | tar xzv; mv r9/f5s/RefStrains210914_NK/f5s/barcode02/*.fast5 fast5_files; rm -rf r9

# Optional: Convert FAST5 to POD5 (recommended format for RawHash2 and benchmark pipeline).
# Requires: conda install -c conda-forge pod5
# Using the benchmark conversion script:
#   SCRIPTS=/path/to/rawhash2/test/benchmark/scripts
#   bash ${SCRIPTS}/1_fast5_to_pod5.sh -i ./fast5_files -o ./pod5_files -t 8
# Or directly:
#   pod5 convert fast5 -r --one-to-one ./fast5_files -t 8 -o ./pod5_files ./fast5_files

#Download FASTQ from SRA (Note: fastq-dump should exist in your path.) | #Processing the FASTA file so that read names contain the read ids as stored in FAST5 files
fastq-dump -Z --fasta 0 ERR9127551 | awk '{if(substr($1,1,1) == ">"){print ">"$2}else{print $0}}' > reads.fasta

#Downloading Escherichia coli CFT073, complete genome (https://www.ncbi.nlm.nih.gov/nuccore/AE014075.1/); Unzip; Change name;
wget https://ftp.ncbi.nlm.nih.gov/genomes/all/GCA/000/007/445/GCA_000007445.1_ASM744v1/GCA_000007445.1_ASM744v1_genomic.fna.gz; gunzip GCA_000007445.1_ASM744v1_genomic.fna.gz; mv GCA_000007445.1_ASM744v1_genomic.fna ref.fa

# Optional: Basecall using dorado (R9.4.1 chemistry, dorado 0.9.2).
# Chemistry: R9.4.1, flowcell FLO-MIN106, sample rate 4kHz.
# Dorado version: 0.9.2 (R9.4.1 models are not available in dorado >= 1.0).
# Model: dna_r9.4.1_e8_hac@v3.3 (specify as full filesystem path).
# Note: dorado 0.9.2 does NOT support --disable-read-splitting, so we pass
#       --enable-read-splitting to the benchmark script to skip that flag.
# Requires pod5_files/ (see conversion above) and a dorado binary.
# Using the benchmark basecalling script:
#   SCRIPTS=/path/to/rawhash2/test/benchmark/scripts
#   DORADO=/path/to/dorado-0.9.2-linux-x64
#   bash ${SCRIPTS}/3_run_dorado.sh \
#     -b ${DORADO}/bin/dorado \
#     -m ${DORADO}/bin/dna_r9.4.1_e8_hac@v3.3 \
#     -i ./pod5_files -o ./dorado-0.9.2 -t 16 \
#     --enable-read-splitting
# Output: dorado-0.9.2/reads.bam, dorado-0.9.2/reads.fasta

cd ..
