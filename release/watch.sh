#!/usr/bin/env bash
# Call the endpoint every 5 seconds with the 1,000 known bookings and print how many
# it flags. The number tells you which model answered. Stop it with Ctrl-C.
#
#     release/watch.sh
cd "$(dirname "$0")/.."
source release/config.sh
mkdir -p scratch
while true; do
  if aws sagemaker-runtime invoke-endpoint --endpoint-name "$ENDPOINT" --content-type text/csv \
       --body fileb://data/live.csv scratch/watch.txt >/dev/null 2>scratch/watch.err; then
    echo "$(date +%H:%M:%S) answered, flagged $(awk '$1 > 0.5 { n++ } END { print n + 0 }' scratch/watch.txt)"
  else
    echo "$(date +%H:%M:%S) NO ANSWER: $(head -c 100 scratch/watch.err | tr '\n' ' ')"
  fi
  sleep 5
done
