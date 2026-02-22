#!/bin/bash

mkdir -p d5_human_na12878_r94/fast5_files/
cd d5_human_na12878_r94

#Download FAST5 from https://github.com/nanopore-wgs-consortium/NA12878/blob/master/Genome.md
wget -qO- http://s3.amazonaws.com/nanopore-human-wgs/rel6/MultiFast5Tars/FAB42260-4177064552_Multi_Fast5.tar | tar xv

find ./UBC -type f -name '*.fast5' | xargs -i{} mv {} ./fast5_files/;

#Download FASTQ
wget -qO- http://s3.amazonaws.com/nanopore-human-wgs/rel6/FASTQTars/FAB42260-4177064552_Multi.tar | tar xv

zcat UBC/FAB42260-4177064552_Multi/fastq/*.fastq.gz | awk 'BEGIN{line = 0}{line++; if(line %4 == 1){print ">"substr($1,2,36)}else if(line % 4 == 2){print $0}}' > reads.fasta

rm -rf UBC;

#Downloading CHM13v2 (hs1) Human reference genome
wget https://hgdownload.soe.ucsc.edu/goldenPath/hs1/bigZips/hs1.fa.gz; gunzip hs1.fa.gz; mv hs1.fa ref.fa

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

cd ..
