#!/usr/bin/env bash
# Send the 1,000 known bookings to the endpoint and count what it flags.
#
#     release/check_live.sh
set -euo pipefail
cd "$(dirname "$0")/.."
source release/config.sh
mkdir -p scratch
aws sagemaker-runtime invoke-endpoint --endpoint-name "$ENDPOINT" --content-type text/csv \
  --body fileb://data/live.csv scratch/answers.txt >/dev/null
paste -d, scratch/answers.txt data/live_labels.csv | awk -F, '
  $2 == 1  { cancelled++ }
  $1 > 0.5 { flagged++; if ($2 == 0) came++ }
  END { printf "bookings %d, really cancelled %d, flagged %d, flagged but the guest came %d\n", NR, cancelled, flagged, came }'
