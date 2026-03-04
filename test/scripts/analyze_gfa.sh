#!/bin/bash

# Check if a GFA file path is provided
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <gfa_file>"
    exit 1
fi

gfa_file="$1"

# Use awk to parse the GFA file
awk '
    function format_number(number) {
        # Format number with commas for thousands separators
        return sprintf("%\047d", number);
    }

    # Check if the line starts with "S" and contains contig length
    /^S/ && /LN:i:/ {
        # Extract the contig length after "LN:i:"
        match($0, /LN:i:([0-9]+)/, arr);
        contig_length = arr[1];
        
        # Sum the total length for calculating the average later
        total_length += contig_length;
        
        # Increment the count of contigs
        count += 1;
        
        # Track the maximum length
        if (contig_length > max_length) {
            max_length = contig_length;
        }
    }
    END {
        # Calculate average length
        if (count > 0) {
            average_length = total_length / count;
        } else {
            average_length = 0; # In case there are no contigs
        }
        
        # Output the results with formatted numbers
        printf "Number of contigs: %s\n", format_number(count);
        printf "Maximum contig length: %s\n", format_number(max_length);
        printf "Average contig length: %s\n", format_number(average_length);
    }
' "$gfa_file"

