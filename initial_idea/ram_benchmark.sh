#!/bin/bash

echo -e "STARTING -----------------------------"

# Check if a filename is provided as an argument
if [ -z "$1" ]; then
  echo -e "Usage: $0 <output_filename>"
  exit 1
fi

output_file="$1"


echo -e "######################################################### \n" > "$output_file"
echo -e "######################################################### \n" >> "$output_file"
echo -e "RESULTS FOR WRITE SEQUENTIAL 1 THREAD \n" >> "$output_file"
sysbench memory --memory-block-size=1G --memory-total-size=160G --memory-oper=write --threads=1 run >> "$output_file"
echo -e "\n" >> "$output_file"


echo -e "######################################################### \n" >> "$output_file"
echo -e "######################################################### \n" >> "$output_file"
echo -e "RESULTS FOR WRITE SEQUENTIAL N THREADS \n" >> "$output_file"
sysbench memory --memory-block-size=1G --memory-total-size=160G --memory-oper=write --threads="$(nproc)" run >> "$output_file"
echo -e "\n" >> "$output_file"

echo -e "######################################################### \n" >> "$output_file"
echo -e "######################################################### \n" >> "$output_file"
echo -e "RESULTS FOR WRITE RANDOM 1 THREAD \n" >> "$output_file"
sysbench memory --memory-block-size=1G --memory-total-size=160G --memory-oper=write --threads=1 --memory-access-mode=rnd run >> "$output_file"
echo -e "\n" >> "$output_file"

echo -e "######################################################### \n" >> "$output_file"
echo -e "######################################################### \n" >> "$output_file"
echo -e "RESULTS FOR WRITE RANDOM N THREADS \n" >> "$output_file"
sysbench memory --memory-block-size=1G --memory-total-size=160G --memory-oper=write --threads="$(nproc)" --memory-access-mode=rnd run >> "$output_file"
echo -e "\n" >> "$output_file"

echo -e "######################################################### \n" >> "$output_file"
echo -e "######################################################### \n" >> "$output_file"
echo -e "RESULTS FOR READ SEQUENTIAL 1 THREAD \n" >> "$output_file"
sysbench memory --memory-block-size=1G --memory-total-size=160G --memory-oper=read --threads=1 run >> "$output_file"
echo -e "\n" >> "$output_file"

echo -e "######################################################### \n" >> "$output_file"
echo -e "######################################################### \n" >> "$output_file"
echo -e "RESULTS FOR READ SEQUENTIAL N THREADS \n" >> "$output_file"
sysbench memory --memory-block-size=1G --memory-total-size=160G --memory-oper=read --threads="$(nproc)" run >> "$output_file"
echo -e "\n" >> "$output_file"

echo -e "######################################################### \n" >> "$output_file"
echo -e "######################################################### \n" >> "$output_file"
echo -e "RESULTS FOR READ RANDOM 1 THREAD \n" >> "$output_file"
sysbench memory --memory-block-size=1G --memory-total-size=160G --memory-oper=read --memory-access-mode=rnd --threads=1 run >> "$output_file"
echo -e "\n" >> "$output_file"

echo -e "######################################################### \n" >> "$output_file"
echo -e "######################################################### \n" >> "$output_file"
echo -e "RESULTS FOR READ RANDOM N THREADS \n" >> "$output_file"
sysbench memory --memory-block-size=1G --memory-total-size=160G --memory-oper=read --memory-access-mode=rnd --threads="$(nproc)" run >> "$output_file"
echo -e "\n" >> "$output_file"

echo -e "DONE -----------------------------"
