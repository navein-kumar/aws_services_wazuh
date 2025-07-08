root@ip-172-31-1-148:/etc/vector# cat /usr/bin/rds-cloudwatch.sh
#!/bin/bash

# RDS CloudWatch Log Fetcher Script for Vector
# Called by Vector exec source every 5 minutes

LOG_GROUP="/aws/rds/instance/production-easebuzz-db/audit"
REGION="ap-south-1"
LAST_TIMESTAMP_FILE="/tmp/rds_last_timestamp.txt"

# Get last timestamp or default to 5 minutes ago
if [[ -f "$LAST_TIMESTAMP_FILE" ]]; then
    START_TIME=$(cat "$LAST_TIMESTAMP_FILE")
else
    START_TIME=$(date -d "5 minutes ago" +%s)000
fi

# Current time in milliseconds
END_TIME=$(date +%s)000

# Fetch logs from CloudWatch
aws logs filter-log-events \
    --log-group-name "$LOG_GROUP" \
    --region "$REGION" \
    --start-time "$START_TIME" \
    --end-time "$END_TIME" \
    --output text \
    --query 'events[*].message' \
    2>/dev/null

# Save timestamp for next run only if command succeeded
if [[ $? -eq 0 ]]; then
    echo "$END_TIME" > "$LAST_TIMESTAMP_FILE"
fi
root@ip-172-31-1-148:/etc/vector#
---

root@ip-172-31-1-148:/etc/vector# cat rdp_mysql.yaml
sources:
  rds_exec:
    type: "exec"
    mode: "scheduled"
    scheduled:
      exec_interval_secs: 300
    command:
      - "/usr/bin/rds-cloudwatch.sh"

transforms:
  parse_rds_complete:
    type: "remap"
    inputs: ["rds_exec"]
    source: |
      message = string!(.message)

      # Use regex to properly parse the 11-field format
      # Format: timestamp,serverhost,username,host,connectionid,queryid,operation,database,query,retcode,ssl
      regex_pattern = r'^([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]*),(.*),([^,]*),([^,]*)$'

      if match(message, regex_pattern) {
        parsed = parse_regex!(message, regex_pattern)

        .mysql_timestamp = parsed[0]
        .mysql_serverhost = parsed[1]
        .mysql_username = parsed[2]
        .mysql_host = parsed[3]
        .mysql_connection_id = parsed[4]
        .mysql_query_id = parsed[5]
        .mysql_operation = parsed[6]
        .mysql_database = parsed[7]
        .mysql_query_full = parsed[8]
        .mysql_retcode = parsed[9]
        .mysql_ssl_info = parsed[10]
      } else {
        # Fallback: capture everything after database field as query_full
        fields = split!(message, ",")
        if length(fields) >= 8 {
          .mysql_timestamp = fields[0]
          .mysql_serverhost = fields[1]
          .mysql_username = fields[2]
          .mysql_host = fields[3]
          .mysql_connection_id = fields[4]
          .mysql_query_id = fields[5]
          .mysql_operation = fields[6]
          .mysql_database = fields[7]

          # Join everything from field 8 onwards as complete query
          remaining_fields = slice!(fields, 8, -1)
          .mysql_query_full = join!(remaining_fields, ",")
          .mysql_retcode = null
          .mysql_ssl_info = null
        }
      }

      # Store original message for reference
      .mysql_original_log = message

      # Add metadata
      .source_type = "rds_mysql_audit"
      .log_group = "/aws/rds/instance/production-easebuzz-db/audit"
      .timestamp = now()

      del(.message)

sinks:
  elasticsearch_rds:
    type: "elasticsearch"
    inputs: ["parse_rds_complete"]
    endpoints: ["https://172.31.1.148:59200"]
    auth:
      user: "admin"
      password: "passs"
      strategy: "basic"
    tls:
      verify_certificate: false
    bulk:
      index: "ebz-rds-mysql-%Y.%m.%d"
      action: "index"
    buffer:
      type: "memory"
      max_events: 5000
      when_full: "block"
