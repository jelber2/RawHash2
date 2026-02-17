#!/bin/bash

uncalled pafstats -r ../true_mappings.paf --annotate ../rawhash2/d9_ecoli_r1041_rawhash2_sensitive.paf > d9_ecoli_r1041_rawhash2_sensitive_ann.paf 2> d9_ecoli_r1041_rawhash2_sensitive.throughput
uncalled pafstats -r ../true_mappings.paf --annotate ../rawhash2/d9_ecoli_r1041_w3_rawhash2_sensitive.paf > d9_ecoli_r1041_w3_rawhash2_sensitive_ann.paf 2> d9_ecoli_r1041_w3_rawhash2_sensitive.throughput

python ../../../../scripts/analyze_paf.py d9_ecoli_r1041_rawhash2_sensitive_ann.paf > d9_ecoli_r1041_rawhash2_sensitive.comparison
python ../../../../scripts/analyze_paf.py d9_ecoli_r1041_w3_rawhash2_sensitive_ann.paf > d9_ecoli_r1041_w3_rawhash2_sensitive.comparison
