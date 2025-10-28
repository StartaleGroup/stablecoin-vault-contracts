#!/bin/bash
# Script to display per-file coverage summary from lcov.info
# Works around the lcov --list bug with filtered files

LCOV_FILE="${1:-lcov.info}"

if [ ! -f "$LCOV_FILE" ]; then
    echo "Error: $LCOV_FILE not found"
    exit 1
fi

# Parse lcov.info and calculate coverage per file
awk '
BEGIN {
    print "[src/]"
    total_lines_hit = 0; total_lines_found = 0
    total_funcs_hit = 0; total_funcs_found = 0
    total_branch_hit = 0; total_branch_found = 0
}

/^SF:/ {
    if (file != "") {
        # Print previous file stats
        print_file_stats()
    }
    file = $0
    sub(/^SF:/, "", file)
    sub(/.*\/src\//, "", file)
    lines_hit = 0; lines_found = 0
    funcs_hit = 0; funcs_found = 0
    branch_hit = 0; branch_found = 0
}

/^FNF:/ {
    split($0, parts, ":")
    funcs_found = parts[2]
}

/^FNH:/ {
    split($0, parts, ":")
    funcs_hit = parts[2]
}

/^DA:/ {
    lines_found++
    split($0, parts, ",")
    if (parts[2] > 0) lines_hit++
}

/^BRDA:/ {
    branch_found++
    split($0, parts, ",")
    if (parts[4] != "-" && parts[4] > 0) branch_hit++
}

END {
    if (file != "") {
        print_file_stats()
    }
    print "====================================================================="
    
    # Print totals
    printf "%-36s", "Total:"
    if (total_lines_found > 0) {
        line_pct = (total_lines_hit * 100.0) / total_lines_found
        printf "| %4.1f%% %5d", line_pct, total_lines_found
    } else {
        printf "|    -     0"
    }
    
    if (total_funcs_found > 0) {
        func_pct = (total_funcs_hit * 100.0) / total_funcs_found
        printf "|%4.1f%% %3d", func_pct, total_funcs_found
    } else {
        printf "|    -   0"
    }
    
    if (total_branch_found > 0) {
        branch_pct = (total_branch_hit * 100.0) / total_branch_found
        printf "|%5.1f%% %5d\n", branch_pct, total_branch_found
    } else {
        printf "|    -     0\n"
    }
}

function print_file_stats() {
    # Truncate filename if too long
    display_file = file
    if (length(display_file) > 36) {
        display_file = substr(display_file, 1, 15) "..." substr(display_file, length(display_file)-17)
    }
    printf "%-36s", display_file
    
    # Lines
    if (lines_found > 0) {
        line_pct = (lines_hit * 100.0) / lines_found
        printf "| %4.1f%% %5d", line_pct, lines_found
        total_lines_hit += lines_hit
        total_lines_found += lines_found
    } else {
        printf "|    -     0"
    }
    
    # Functions
    if (funcs_found > 0) {
        func_pct = (funcs_hit * 100.0) / funcs_found
        printf "| %3.1f%% %2d", func_pct, funcs_found
        total_funcs_hit += funcs_hit
        total_funcs_found += funcs_found
    } else {
        printf "|    -  0"
    }
    
    # Branches
    if (branch_found > 0) {
        branch_pct = (branch_hit * 100.0) / branch_found
        printf "|%5.1f%% %5d\n", branch_pct, branch_found
        total_branch_hit += branch_hit
        total_branch_found += branch_found
    } else {
        printf "|    -     0\n"
    }
}
' "$LCOV_FILE"
