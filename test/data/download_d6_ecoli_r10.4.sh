#!/bin/bash

mkdir -p d6_ecoli_r104/fast5_files/
cd d6_ecoli_r104

#Download FAST5 from AWS | Unzip; Mv FAST5 files into the fast5_files directory. NCBI SRA Link: https://trace.ncbi.nlm.nih.gov/Traces/?run=ERR9127552
wget -qO- https://sra-pub-src-2.s3.amazonaws.com/ERR9127552/Ecoli_r10.4.tar.gz.1 | tar xzv; mv ./mnt/data/analysis/nick/q20_refstrains/data/r10.4/fast5s/211123Ecoli_Q20_112/f5s/*.fast5 fast5_files; rm -rf ./mnt

# Optional: Convert FAST5 to POD5 (recommended format for RawHash2 and benchmark pipeline).
# Requires: conda install -c conda-forge pod5
# Using the benchmark conversion script:
#   SCRIPTS=/path/to/rawhash2/test/benchmark/scripts
#   bash ${SCRIPTS}/1_fast5_to_pod5.sh -i ./fast5_files -o ./pod5_files -t 8
# Or directly:
#   pod5 convert fast5 -r --one-to-one ./fast5_files -t 8 -o ./pod5_files ./fast5_files

#Download FASTQ from SRA (Note: fastq-dump should exist in your path.) | #Processing the FASTA file so that read names contain the read ids as stored in FAST5 files
fastq-dump -Z --fasta 0 ERR9127552 | awk '{if(substr($1,1,1) == ">"){print ">"$2}else{print $0}}' > reads.fasta

#Downloading Escherichia coli CFT073, complete genome (https://www.ncbi.nlm.nih.gov/nuccore/AE014075.1/); Unzip; Change name;
wget https://ftp.ncbi.nlm.nih.gov/genomes/all/GCA/000/007/445/GCA_000007445.1_ASM744v1/GCA_000007445.1_ASM744v1_genomic.fna.gz; gunzip GCA_000007445.1_ASM744v1_genomic.fna.gz; mv GCA_000007445.1_ASM744v1_genomic.fna ref.fa

# Optional: Basecall using dorado (R10.4 e8.1 chemistry, dorado 0.9.2).
# Chemistry: R10.4 e8.1, flowcell FLO-MIN112, kit SQK-Q20EA, sample rate 4kHz.
#   basecall_config_filename in fast5: dna_r10.4_e8.1_hac.cfg
# Dorado version: 0.9.2.
# Model: dna_r10.4.1_e8.2_400bps_hac@v4.1.0 (specify as full filesystem path).
# Requires pod5_files/ (see conversion above) and a dorado binary.
# Using the benchmark basecalling script:
#   SCRIPTS=/path/to/rawhash2/test/benchmark/scripts
#   DORADO=/path/to/dorado-0.9.2-linux-x64
#   bash ${SCRIPTS}/3_run_dorado.sh \
#     -b ${DORADO}/bin/dorado \
#     -m ${DORADO}/bin/dna_r10.4.1_e8.2_400bps_hac@v4.1.0 \
#     -i ./pod5_files -o ./dorado-0.9.2 -t 16
# Output: dorado-0.9.2/reads.bam, dorado-0.9.2/reads.fasta

cd ..
