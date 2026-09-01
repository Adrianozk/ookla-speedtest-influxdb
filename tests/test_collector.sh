#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/bin"

cat >"$TEST_ROOT/bin/speedtest" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"$SPEEDTEST_ARGS_FILE"
cat "$SPEEDTEST_FIXTURE"
EOF

cat >"$TEST_ROOT/bin/curl" <<'EOF'
#!/bin/sh
while [ "$#" -gt 0 ]; do
    if [ "$1" = "--data-binary" ]; then
        shift
        printf '%s' "$1" >"$CAPTURE_FILE"
        exit 0
    fi
    shift
done
exit 1
EOF

chmod +x "$TEST_ROOT/bin/speedtest" "$TEST_ROOT/bin/curl"

export PATH="$TEST_ROOT/bin:$PATH"
export CAPTURE_FILE="$TEST_ROOT/line-protocol.txt"
export SPEEDTEST_ARGS_FILE="$TEST_ROOT/speedtest-args.txt"
export SPEEDTEST_FIXTURE="$PROJECT_ROOT/tests/fixtures/speedtest-result.json"
export INFLUX_URL="http://influxdb:8086"
export INFLUX_ORG="example-org"
export INFLUX_BUCKET="speedtests"
export INFLUX_TOKEN="test-token"
export SPEEDTEST_SERVER_ID="30306"
export HOST_TAG="cerberus"
export RUN_ONCE="true"

"$PROJECT_ROOT/scripts/collector.sh"

grep -Fx -- '--server-id=30306' "$SPEEDTEST_ARGS_FILE" >/dev/null

unset SPEEDTEST_SERVER_ID
"$PROJECT_ROOT/scripts/collector.sh"

if grep -E '^--server-id=' "$SPEEDTEST_ARGS_FILE" >/dev/null; then
    echo 'Automatic server selection unexpectedly passed --server-id' >&2
    exit 1
fi

line="$(cat "$CAPTURE_FILE")"

grep -F 'speedtest,host=cerberus,server_id=30306' <<<"$line" >/dev/null
grep -F 'server_name=Example\ Server' <<<"$line" >/dev/null
grep -F 'isp=Example\ ISP' <<<"$line" >/dev/null
grep -F 'download_mbps=1000' <<<"$line" >/dev/null
grep -F 'upload_mbps=500' <<<"$line" >/dev/null
grep -F 'latency_ms=12.5' <<<"$line" >/dev/null
grep -F 'packet_loss_pct=0' <<<"$line" >/dev/null

if grep -F 'test-token' "$CAPTURE_FILE" >/dev/null; then
    echo 'Token leaked into line protocol' >&2
    exit 1
fi

echo 'collector test passed'
