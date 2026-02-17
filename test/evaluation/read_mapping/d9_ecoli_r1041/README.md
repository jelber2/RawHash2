# Read Mapping - d9_ecoli_r1041 (R10.4.1)

We assume your current directory points to this directory ([`d9_ecoli_r1041`](./)).

## RawHash2

Run RawHash2 to map the raw nanopore signals to the corresponding reference genome. This will create the `rawhash2` directory including a `PAF` file that stores the mapping output from RawHash2.

The following command will use 32 threads. You can change the maximum threads to use by providing a different value than 32 below.

```bash
bash run_rawhash2.sh 32
```

## Ground truth mapping (minimap2)

Run minimap2 to map the basecalled sequences to the corresponding reference genome. This will create the `true_mappings.paf` file that includes the ground truth mapping output from minimap2.

The following command will use 32 threads. You can change the maximum threads to use by providing a different value than 32 below.

```bash
bash run_minimap2.sh 32
```

## Comparing RawHash2 to minimap2

After generating the `PAF` files by following each step above, run the following command. This will 1) generate the files to evaluate the mapping output of RawHash2 and 2) output the results (i.e., throughput, mean time per read, indexing time, mapping time, precision, recall, and F1 values).

```bash
cd comparison
bash 0_run.sh

#After running 0_run.sh, if you want to just summarize the results again without generating the evaluation files, you can alternatively run the following command:
# bash 2_output_results.sh

cd ..
```
