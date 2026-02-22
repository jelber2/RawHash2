#!/bin/bash

mkdir -p d1_sars-cov-2_r94/fast5_files/
cd d1_sars-cov-2_r94

#Download FAST5 and FASTQ Caddecentre
wget -qO-  https://cadde.s3.climb.ac.uk/SP1-raw.tgz | tar -xzv; rm README

#Moving the fast5 files to fast5_files
find ./SP1-fast5-mapped -type f -name '*.fast5' | xargs -i{} mv {} ./fast5_files/; rm -rf SP1-fast5-mapped; 

#Converting FASTQ to FASTA files
awk 'BEGIN{line = 0}{line++; if(line %4 == 1){print ">"substr($1,2)}else if(line % 4 == 2){print $0}}' SP1-mapped.fastq > reads.fasta; rm SP1-mapped.fastq

#Downloading SARS-CoV-2 (covid) reference genome from RefSeq
wget https://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/009/858/895/GCF_009858895.2_ASM985889v3/GCF_009858895.2_ASM985889v3_genomic.fna.gz; gunzip GCF_009858895.2_ASM985889v3_genomic.fna.gz; mv GCF_009858895.2_ASM985889v3_genomic.fna ref.fa;

# Optional: Convert FAST5 to POD5 (recommended format for RawHash2 and benchmark pipeline).
# Requires: conda install -c conda-forge pod5
# Using the benchmark conversion script:
#   SCRIPTS=/path/to/rawhash2/test/benchmark/scripts
#   bash ${SCRIPTS}/1_fast5_to_pod5.sh -i ./fast5_files -o ./pod5_files -t 8
# Or directly:
#   pod5 convert fast5 -r --one-to-one ./fast5_files -t 8 -o ./pod5_files ./fast5_files

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
# Symlink so that evaluation scripts find reads.fasta at the dataset root:
#   ln -sf dorado-0.9.2/reads.fasta reads.fasta

cd ..
