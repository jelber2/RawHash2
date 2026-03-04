import os
import sys
import argparse
import subprocess
import fileinput

from statistics import median
from statistics import mean
from math import sqrt

if (len(sys.argv) < 2):
  print("usage: test_paf_relative.py rawhash_ann.paf true_mappings.paf")
  sys.exit(1)

fps = []
for tool in [1, 2]:
  fps.append(open(sys.argv[tool]))

true_mappings = {}
for line in fps[1]:
  cols = line.rstrip().split()
  read_id = cols[0]
  true_mappings[read_id] = cols[5] if cols[5] != '*' else None  # Check for unmapped reads

rawhash2_tp = 0
rawhash2_fp = 0
rawhash2_fn = 0
rawhash2_tn = 0

# Add the calculation code at the end
counts = {'ecoli': 0, 'yeast': 0, 'green_algae': 0, 'human': 0, 'covid': 0}
sums = {'ecoli': 0, 'yeast': 0, 'green_algae': 0, 'human': 0, 'covid': 0}
total_count = 0
total_sum = 0

rawhash2_time_per_chunk = []
rawhash2_time_per_read = []
rawhash2_maplast_pos = []
rawhash2_maplast_chunk = []
rawhash2_umaplast_pos = []
rawhash2_umaplast_chunk = []
rawhash2_refgap = []
rawhash2_readgap = []
for line in fps[0]:
  cols = line.rstrip().split()
  read_id = cols[0]
  mapped_genome = cols[5] if cols[5] != '*' else None  # Check for unmapped reads
  true_genome = true_mappings.get(read_id, None)
  if true_genome:
    if mapped_genome == true_genome:
      rawhash2_tp += 1
    else:
      rawhash2_fp += 1
  else:
    if mapped_genome:
      rawhash2_fp += 1
    else:
      rawhash2_tn += 1
  if not mapped_genome and true_genome:
      rawhash2_fn += 1
  if (len(cols) == 20):
    mt = float(cols[12].split(":")[2])
    lastpos = int(cols[1])

    reference = cols[5]
    start = cols[2]
    end = cols[3]

    if start != "*" and end != "*" and int(end) >= int(start):
      total_count += 1
      total_sum += int(end) - int(start)
      
      for species in ['ecoli', 'yeast', 'green_algae', 'human', 'covid']:
          if reference.startswith(species):
              counts[species] += 1
              sums[species] += int(end) - int(start)
              break
    
    if (cols[19].split(":")[2] != 'na'):
      rawhash2_time_per_read.append(mt)
      if(cols[2] != '*'):
        rawhash2_maplast_pos.append(lastpos)
      else:
        rawhash2_umaplast_pos.append(lastpos)
    chunk = int(cols[13].split(":")[2])
    if(cols[2] != '*'):
      rawhash2_maplast_chunk.append(chunk)
    else:
      rawhash2_umaplast_chunk.append(chunk)
    cm = int(cols[15].split(":")[2])
    nc = int(cols[16].split(":")[2])
    s1 = float(cols[17].split(":")[2])
    # s2 = float(cols[18].split(":")[2])
    sm = float(cols[18].split(":")[2])
    if (cols[19].split(":")[2] == 'tp'):
      rawhash2_time_per_chunk.append(mt / chunk)
    if (cols[19].split(":")[2] == 'fp' or cols[19].split(":")[2] == 'na'):
      rawhash2_time_per_chunk.append(mt / chunk)
    if (cols[19].split(":")[2] == 'fn'):
      rawhash2_time_per_chunk.append(mt / chunk)
    if (cols[19].split(":")[2] == 'tn'):
      rawhash2_time_per_chunk.append(mt / chunk)
  if (len(cols) == 15):
    mt = float(cols[12].split(":")[2])
    if (cols[14].split(":")[2] != 'na'):
      rawhash2_time_per_read.append(mt)

fps[0].close()

print("RawHash2 TP: " + str(rawhash2_tp))
print("RawHash2 FP: " + str(rawhash2_fp))
print("RawHash2 FN: " + str(rawhash2_fn))
print("RawHash2 TN: " + str(rawhash2_tn))
rawhash2_precision = rawhash2_tp / (rawhash2_tp + rawhash2_fp)
print("RawHash2 precision: " + str(rawhash2_precision))
rawhash2_recall = rawhash2_tp / (rawhash2_tp + rawhash2_fn)
print("RawHash2 recall: " + str(rawhash2_recall))
print("RawHash2 F-1 score: " + str(2 * rawhash2_precision * rawhash2_recall / (rawhash2_precision + rawhash2_recall)))

# Calculate and print ratios
ratio_counts = {k: v / total_count for k, v in counts.items()}
ratio_sums = {k: v / total_sum for k, v in sums.items()}

print(f"Ratio of reads: covid: {ratio_counts['covid']} ecoli: {ratio_counts['ecoli']} yeast: {ratio_counts['yeast']} green_algae: {ratio_counts['green_algae']} human: {ratio_counts['human']}")
print(f"Ratio of bases: covid: {ratio_sums['covid']} ecoli: {ratio_sums['ecoli']} yeast: {ratio_sums['yeast']} green_algae: {ratio_sums['green_algae']} human: {ratio_sums['human']}")

# Calculate Euclidean distance
comparison_vector = {'covid': 0.6329, 'ecoli': 0.1582, 'yeast': 0.0224, 'green_algae': 0.0283, 'human': 0.1582}
euclidean_distance = sqrt(sum((ratio_counts[key] - comparison_vector[key]) ** 2 for key in ratio_counts.keys()))
print(f"Euclidean distance: {euclidean_distance}")
