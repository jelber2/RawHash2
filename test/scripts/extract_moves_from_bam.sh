#!/usr/bin/env bash
# Extract move table data from a dorado BAM file for use with rawhash2 --moves-file.
# Requires: samtools
#
# Usage: ./extract_moves_from_bam.sh <input.bam> > moves.tsv
#
# Output format (tab-separated, one line per read):
#   read_id    mv:B:c,STRIDE,0,1,...    ts:i:OFFSET
#
# The mv tag contains the move table from dorado basecalling.
# The ts tag contains the template_start sample offset.
#
# Example:
#   ./extract_moves_from_bam.sh reads_dorado.bam > moves.tsv
#   rawhash2 --moves-file moves.tsv -p pore_model.txt -d ref.ind ref.fa pod5_dir/

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <input.bam> > moves.tsv" >&2
    echo "" >&2
    echo "Extract move table data from a dorado BAM for rawhash2 --moves-file." >&2
    echo "Requires: samtools" >&2
    exit 1
fi

BAM="$1"

if ! command -v samtools &> /dev/null; then
    echo "Error: samtools not found. Please install samtools first." >&2
    exit 1
fi

if [ ! -f "$BAM" ]; then
    echo "Error: File not found: $BAM" >&2
    exit 1
fi

samtools view "$BAM" | awk '{
    id = $1
    mv = ""
    ts = ""
    for (i = 12; i <= NF; i++) {
        if ($i ~ /^mv:/) mv = $i
        if ($i ~ /^ts:/) ts = $i
    }
    if (mv != "" && ts != "") print id "\t" mv "\t" ts
}'
