#!/bin/bash

THREAD=$1

bash ../../../scripts/run_minimap2.sh . ../../../data/d10_dmelanogaster_r1041/reads.fasta ../../../data/d10_dmelanogaster_r1041/ref.fa ${THREAD}
