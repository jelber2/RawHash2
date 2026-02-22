#!/bin/bash

mkdir -p d3_yeast_r94/fast5_files/
cd d3_yeast_r94

#Download FAST5 from AWS. NCBI SRA Accession: https://trace.ncbi.nlm.nih.gov/Traces/index.html?view=run_browser&acc=SRR8648503&display=metadata
wget -qO- https://sra-pub-src-1.s3.amazonaws.com/SRR8648503/GLU1II_basecalled_fast5_1.tar.gz.1 | tar -xzv;

find ./GLU1II_basecalled_fast5_1 -type f -name '*.fast5' | head -50000 | xargs -i{} mv {} ./fast5_files/; rm -rf GLU1II_basecalled_fast5_1;

#To extract the reads from FAST5 from this dataset, you will need to clone the following repository and make sure you have h5py <= 2.9 (if you have conda you can do the following):
conda create -n oldh5 h5py=2.9.0; conda activate oldh5;
git clone https://github.com/rrwick/Fast5-to-Fastq
Fast5-to-Fastq/fast5_to_fastq.py fast5_files/ | awk 'BEGIN{line = 0}{line++; if(line %4 == 1){print ">"substr($1,2,36)}else if(line % 4 == 2){print $0}}' > reads.fasta

# Optional: Single to multi conversion. Requires the following tool: https://github.com/nanoporetech/ont_fast5_api
# single_to_multi_fast5 -i ./fast5_files/ -s ./multi_fast5_files_test/ -n 4000 -t 32 -c vbz
# rm -rf ./fast5_files; mv ./multi_fast5_files/ ./fast5_files;

# Optional: Convert FAST5 to POD5 (recommended format for RawHash2 and benchmark pipeline).
# Note: Single to multi conversion (see above) must be performed to convert these fast5 files to pod5.
# Requires: conda install -c conda-forge pod5
# Using the benchmark conversion script:
#   SCRIPTS=/path/to/rawhash2/test/benchmark/scripts
#   bash ${SCRIPTS}/1_fast5_to_pod5.sh -i ./fast5_files -o ./pod5_files -t 8
# Or directly:
#   pod5 convert fast5 -r --one-to-one ./fast5_files -t 8 -o ./pod5_files ./fast5_files

#We have provided the Zenodo link to this reads.fasta file to avoid the hassle above
# wget https://zenodo.org/record/7582018/files/reads.fasta

#Downloading S.cerevisiae S288c (Yeast) reference genome from UCSC
wget https://hgdownload.soe.ucsc.edu/goldenPath/sacCer3/bigZips/sacCer3.fa.gz; gunzip sacCer3.fa.gz; mv sacCer3.fa ref.fa;

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
