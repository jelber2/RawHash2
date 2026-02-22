#!/bin/bash

uncalled pafstats -r ../true_mappings.paf --annotate ../rawhash2/d8_human_hg002_r1041_rawhash2_fast.paf > d8_human_hg002_r1041_rawhash2_fast_ann.paf 2> d8_human_hg002_r1041_rawhash2_fast.throughput
uncalled pafstats -r ../true_mappings.paf --annotate ../rawhash2/d8_human_hg002_r1041_w3_rawhash2_fast.paf > d8_human_hg002_r1041_w3_rawhash2_fast_ann.paf 2> d8_human_hg002_r1041_w3_rawhash2_fast.throughput

python ../../../../scripts/analyze_paf.py d8_human_hg002_r1041_rawhash2_fast_ann.paf > d8_human_hg002_r1041_rawhash2_fast.comparison
python ../../../../scripts/analyze_paf.py d8_human_hg002_r1041_w3_rawhash2_fast_ann.paf > d8_human_hg002_r1041_w3_rawhash2_fast.comparison
