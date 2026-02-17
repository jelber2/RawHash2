#!/bin/bash

THREAD=$1

bash ../../../scripts/run_minimap2.sh . ../../../data/d9_ecoli_r1041/reads.fasta ../../../data/d9_ecoli_r1041/ref.fa ${THREAD}
