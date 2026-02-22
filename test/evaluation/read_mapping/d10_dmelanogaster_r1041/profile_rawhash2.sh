#!/bin/bash

#Please make sure that you compile rawhash2 with the profiling option enabled. In /src/Makefile, you should enable the two lines below the line "# For profiling"

THREAD=$1

#d10_dmelanogaster_r1041
OUTDIR="./rawhash2/"
SIGNALS="../../../data/d10_dmelanogaster_r1041/pod5_files/D_melanogaster_1.pod5"
REF="../../../data/d10_dmelanogaster_r1041/ref.fa"
PORE="../../../../extern/local_kmer_models/uncalled_r1041_model_only_means.txt"
PRESET="sensitive"
mkdir -p ${OUTDIR}

#The following is the run using default parameters:
PREFIX="d10_dmelanogaster_r1041_profile_"${THREAD}
PARAMS="--r10"
bash ../../../scripts/run_rawhash2.sh ${OUTDIR} ${PREFIX} ${SIGNALS} ${REF} ${PORE} ${PRESET} ${THREAD} "${PARAMS}" > "${OUTDIR}/${PREFIX}_rawhash2_${PRESET}.out" 2> "${OUTDIR}/${PREFIX}_rawhash2_${PRESET}.err"
