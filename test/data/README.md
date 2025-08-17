# Datasets for RawHash, RawHash2, and Rawsamble

We assume your current directory points to this directory ([`data`](./))

Download and process each dataset so that they are fully ready to be used in the evaluation step:

## RawHash and RawHash2 Datasets
```bash
bash download_d1_sars-cov-2_r94.sh #Download Dataset D1 SARS-CoV-2
bash download_d2_ecoli_r94.sh #Download Dataset D2 E. coli
bash download_d3_yeast.sh #Download Dataset D3 Yeast
bash download_d4_green_algae.sh #Downlaod Dataset D4 Green Algae
bash download_d5_human_na12878.sh #Download Dataset D5 Human HG001
bash download_d6_ecoli_r10.4.sh #Download Dataset D6 E. coli (R10.4) -- Used in RawHash2
bash download_d7_saureus_r104.sh #Download Dataset D7 S. aureus (R10.4) -- Used in RawHash2

#Prepare the contamination dataset
cd contamination && bash generate_fast5_files.sh && cd ..

#Prepare the relative abundance dataset
cd relative_abundance && bash generate_fast5_files.sh && bash generate_ref.sh && cd ..

#Create a random community of randomly ordered reads from D1-D5 reads read_ids.txt
cd random_community && bash 0_generate_random_ids.sh && bash 1_symbolic_links.sh && cd ..
```

## Rawsamble Datasets

```bash
bash download_d2_ecoli_r94.sh #Download Dataset D1 E. coli
bash download_d3_yeast.sh #Download Dataset D2 Yeast
bash download_d4_green_algae.sh #Downlaod Dataset D3 Green Algae
bash download_d9_ecoli_r1041.sh #Download Dataset D4 E. coli (R10.4.1)
```