#!/bin/bash

uncalled pafstats -r ../true_mappings.paf --annotate ../rawhash2/d10_dmelanogaster_r1041_rawhash2_sensitive.paf > d10_dmelanogaster_r1041_rawhash2_sensitive_ann.paf 2> d10_dmelanogaster_r1041_rawhash2_sensitive.throughput
uncalled pafstats -r ../true_mappings.paf --annotate ../rawhash2/d10_dmelanogaster_r1041_w3_rawhash2_sensitive.paf > d10_dmelanogaster_r1041_w3_rawhash2_sensitive_ann.paf 2> d10_dmelanogaster_r1041_w3_rawhash2_sensitive.throughput

python ../../../../scripts/analyze_paf.py d10_dmelanogaster_r1041_rawhash2_sensitive_ann.paf > d10_dmelanogaster_r1041_rawhash2_sensitive.comparison
python ../../../../scripts/analyze_paf.py d10_dmelanogaster_r1041_w3_rawhash2_sensitive_ann.paf > d10_dmelanogaster_r1041_w3_rawhash2_sensitive.comparison
