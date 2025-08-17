#!/bin/bash

DATASET="d9_ecoli_r1041"
SIGNALS="../../../../test/data/${DATASET}/pod5_files/"
READS="../../../../test/data/${DATASET}/reads.fasta"
PRESET="ava"
PORE="../../../../extern/local_kmer_models/uncalled_r1041_model_only_means.txt"

OUTDIR="rawsamble"
THREAD=$1 #64
PARAMS="--r10"

mkdir -p ${OUTDIR}

INDEX="${OUTDIR}/${DATASET}_rawsamble_${PRESET}.ind"

/usr/bin/time -vpo "${OUTDIR}/${DATASET}_rawsamble_index_${PRESET}.time" rawhash2 -x ${PRESET} -t ${THREAD} -p "${PORE}" -d ${INDEX} "${PARAMS}" ${SIGNALS} > "${OUTDIR}/${DATASET}_rawsamble_index_${PRESET}.out" 2> "${OUTDIR}/${DATASET}_rawsamble_index_${PRESET}.err"

/usr/bin/time -vpo "${OUTDIR}/${DATASET}_rawsamble_map_${PRESET}.time" rawhash2 -x ${PRESET} -t ${THREAD} "${PARAMS}" ${INDEX} ${SIGNALS} > "${OUTDIR}/${DATASET}_rawsamble_${PRESET}.paf" 2> "${OUTDIR}/${DATASET}_rawsamble_${PRESET}.err"

miniasm "${OUTDIR}/${DATASET}_rawsamble_${PRESET}.paf" > "${OUTDIR}/${DATASET}_rawsamble_${PRESET}.gfa"

bash ../../../../test/scripts/analyze_gfa.sh ${OUTDIR}/${DATASET}_rawsamble_${PRESET}.gfa > "${OUTDIR}/${DATASET}_rawsamble_${PRESET}.results"

/usr/bin/time -vpo "${OUTDIR}/mm2_overlaps.time" minimap2 -t ${THREAD} -x ava-ont --for-only ${READS} ${READS} > "${OUTDIR}/mm2_overlaps.paf"
miniasm "${OUTDIR}/mm2_overlaps.paf" > "${OUTDIR}/mm2_overlaps.gfa"
echo "GFA Stats from true mappings:" >> "${OUTDIR}/${DATASET}_rawsamble_${PRESET}.results"
bash ../../../../test/scripts/analyze_gfa.sh  "${OUTDIR}/mm2_overlaps.gfa" >> "${OUTDIR}/${DATASET}_rawsamble_${PRESET}.results"

python3 ../../../../test/scripts/pafstats.py "${OUTDIR}/${DATASET}_rawsamble_${PRESET}.paf" "${OUTDIR}/mm2_overlaps.paf" 2>> "${OUTDIR}/${DATASET}_rawsamble_${PRESET}.results"
