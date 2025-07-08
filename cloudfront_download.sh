#!/bin/bash

# CloudFront Download Script - Final Optimized Version
# Based on actual log analysis: edu (379), teller- (12), tellerv2 (6), capital (5)
# CloudFront logs have 5-6 hour delays

bucket_name="ebz-cloudfront-logs"
local_folder="/tmp/cloudfront_unzipped_logs"
log_file="/tmp/s3_cloudfront_logs.log"
last_date_file="/tmp/cloudfront_last_date.txt"

# Ordered by activity level (most active first)
prefixes=(
    "edu"        # 379 files - highest activity
    "teller-"    # 12 files
    "tellerv2"   # 6 files
    "capital"    # 5 files
    # Commented out inactive services:
    # "backoffice-"
    # "offer-engine"
    # "wire-"
)

log_message() {
    echo "$(date -u +"%Y-%m-%d %H:%M:%S UTC") $1" >> "$log_file"
    echo "$1"
}

construct_path() {
    local prefix=$1
    echo "$bucket_name/$prefix"
}

# Optimized for CloudFront's 5-6 hour delay pattern
process_files() {
    local prefix=$1
    local s3_path=$(construct_path "$prefix")
    log_message "Processing files from prefix: $s3_path"

    mkdir -p "$local_folder"

    # CloudFront logs have 5-6 hour delays, check current and previous day
    local current_utc_date=$(date -u +%Y-%m-%d)
    local previous_utc_date=$(date -u -d "yesterday" +%Y-%m-%d)

    # For very busy services like 'edu', also check 2 days ago to catch any delayed logs
    local previous2_utc_date=$(date -u -d "2 days ago" +%Y-%m-%d)

    local search_pattern=""
    if [ "$prefix" = "edu" ]; then
        # edu is very active (379 files), check 3 days
        search_pattern="($current_utc_date|$previous_utc_date|$previous2_utc_date)"
        log_message "Searching edu (high activity) for dates: $current_utc_date, $previous_utc_date, $previous2_utc_date"
    else
        # Other services, check 2 days
        search_pattern="($current_utc_date|$previous_utc_date)"
        log_message "Searching $prefix for dates: $current_utc_date, $previous_utc_date"
    fi

    # List files and filter by date pattern
    local file_list=$(aws s3 ls "s3://$bucket_name/$prefix/" 2>/dev/null | grep -E "$search_pattern")

    if [[ $? -ne 0 ]]; then
        log_message "Failed to access S3 bucket: $s3_path"
        return 1
    fi

    if [[ -z "$file_list" ]]; then
        log_message "No recent files found in $s3_path"
        return 0
    fi

    local download_count=0
    local skip_count=0
    local total_found=0

    while read -r line; do
        if [[ -z "$line" ]]; then
            continue
        fi

        ((total_found++))

        local filename=$(echo "$line" | awk '{print $4}')
        if [[ -z "$filename" ]]; then
            continue
        fi

        local local_file="$local_folder/$(basename "$filename")"

        # Skip if file already exists
        if [[ -f "$local_file" ]]; then
            ((skip_count++))
            continue
        fi

        # Download file
        aws s3 cp "s3://$bucket_name/$prefix/$filename" "$local_file" >/dev/null 2>&1

        if [[ $? -eq 0 ]]; then
            ((download_count++))

            # Extract date-hour from filename for logging
            local date_hour=$(echo "$filename" | grep -o '[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-[0-9]\{2\}')
            log_message "Downloaded: $filename ($date_hour UTC)"
        else
            log_message "Failed to download: $filename"
        fi

    done <<< "$file_list"

    # Set permissions
    chmod 777 -R "$local_folder" 2>/dev/null

    log_message "Processed $prefix: Found $total_found files, Downloaded $download_count new, Skipped $skip_count existing"
}

# Smart cleanup - keep files longer due to CloudFront delays
check_day_change() {
    local current_utc_date=$(date -u +"%Y%m%d")

    if [[ -f "$last_date_file" ]]; then
        local last_date=$(cat "$last_date_file")
        if [[ "$last_date" != "$current_utc_date" ]]; then
            log_message "UTC date changed from $last_date to $current_utc_date"

            # Keep files for 72 hours due to CloudFront delays (especially for edu)
            log_message "Cleaning files older than 72 hours from $local_folder"
            find "$local_folder" -name "*.gz" -mtime +3 -delete 2>/dev/null || true

            echo "$current_utc_date" > "$last_date_file"
            return 0
        fi
    else
        echo "$current_utc_date" > "$last_date_file"
        return 0
    fi
    return 1
}

# Minimal startup info
show_startup_info() {
    echo "CloudFront download started - $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
}

# Removed verbose status check
test_current_status() {
    return 0
}

# Main execution optimized for CloudFront pattern
main() {
    show_startup_info

    # Initialize with UTC date
    local current_utc_date=$(date -u +"%Y%m%d")
    echo "$current_utc_date" > "$last_date_file"

    local loop_counter=1
    while true; do
        # Check for date change
        check_day_change >/dev/null 2>&1

        # Process all prefixes
        for prefix in "${prefixes[@]}"; do
            process_files "$prefix"
        done

        # Sleep between loops
        sleep 10
    done
}

# Execute main function
main "$@"
