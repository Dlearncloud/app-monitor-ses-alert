# main monitor (explain each line below)

#!/usr/bin/env bash
# monitor.sh - app health monitor + SES alert
# Run: ./scripts/monitor.sh
# Make executable: chmod +x scripts/monitor.sh

# ---- safety / strict-ish mode ----
set -u              # error on unset vars
IFS=$'\n\t'         # safer splitting

# Load configuration (fail early if missing)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config/monitor.conf"
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Missing config file: $CONFIG_FILE" >&2
  exit 2
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"

# Ensure log dir exists
mkdir -p "$(dirname "$LOG_FILE")"

# helper: timestamp
timestamp() { date +"%Y-%m-%d %H:%M:%S"; }

# helper: log function - prints with timestamp and appends to log file
log() {
  echo "$(timestamp) | $*" | tee -a "$LOG_FILE"
}

# helper: perform one check, return codes:
# 0 = OK, 1 = unhealthy (non-expected status or missing body), 2 = curl failed (network)
check_once() {
  local tmp_body
  tmp_body="$(mktemp)"
  # Timeout so check doesn't hang: --max-time 10s
  http_code=$(curl -s -S -o "$tmp_body" -w "%{http_code}" --max-time 10 "$URL") || {
    log "curl failed when calling $URL"
    rm -f "$tmp_body"
    return 2
  }

  # log HTTP code for debugging
  log "Checked $URL -> HTTP $http_code"

  # status code match?
  if [[ "$http_code" -ne "$EXPECTED_STATUS" ]]; then
    log "Unexpected status: expected $EXPECTED_STATUS, got $http_code"
    rm -f "$tmp_body"
    return 1
  fi

  # optional body content check
  if [[ -n "$EXPECTED_BODY_SUBSTRING" ]]; then
    if ! grep -q -- "$EXPECTED_BODY_SUBSTRING" "$tmp_body"; then
      log "Response body did not contain expected substring: $EXPECTED_BODY_SUBSTRING"
      rm -f "$tmp_body"
      return 1
    fi
  fi

  rm -f "$tmp_body"
  return 0
}

# helper: send alert via AWS SES (uses aws cli)
send_alert() {
  local subject="$1"
  local body="$2"
  local tmp_dest tmp_msg
  tmp_dest="$(mktemp)"
  tmp_msg="$(mktemp)"

  # Create destination JSON
  cat > "$tmp_dest" <<EOF
{"ToAddresses": ["$TO_EMAIL"]}
EOF

  # Create message JSON
  cat > "$tmp_msg" <<EOF
{"Subject": {"Data": "$subject"}, "Body": {"Text": {"Data": "$body"}}}
EOF

  log "Sending alert via SES: $subject"
  # Use aws cli. Make sure aws cli is configured or the instance has an IAM role.
  if aws ses send-email --from "$FROM_EMAIL" --destination "file://$tmp_dest" --message "file://$tmp_msg" --region "$AWS_REGION" >> "$LOG_FILE" 2>&1; then
    log "Alert sent (SES CLI success)"
  else
    log "Failed to send alert via SES. Check aws cli configuration / IAM permissions."
  fi

  rm -f "$tmp_dest" "$tmp_msg"
}

# MAIN: loop forever (daemon-style)
log "Starting monitor for $URL (check every $CHECK_INTERVAL s, retry $RETRY_LIMIT times)"
fail_count=0

while true; do
  check_once
  rc=$?
  if [[ $rc -eq 0 ]]; then
    # OK -> reset fail counter
    if [[ $fail_count -ne 0 ]]; then
      log "Service recovered. Resetting fail_count."
    fi
    fail_count=0
  else
    # failure handling
    ((fail_count++))
    log "Failure #$fail_count detected (rc=$rc)."

    if [[ $fail_count -lt $RETRY_LIMIT ]]; then
      log "Will retry after $RETRY_DELAY seconds..."
      sleep "$RETRY_DELAY"
      continue
    fi

    # fail_count >= RETRY_LIMIT -> send alert and reset counter
    subject="$SUBJECT_PREFIX Service DOWN: $URL"
    body="Monitor detected $fail_count consecutive failures for $URL on $(hostname) at $(timestamp). Please investigate."
    send_alert "$subject" "$body"

    # After alert, reset fail count so we don't flood with emails
    fail_count=0
  fi

  sleep "$CHECK_INTERVAL"
done
