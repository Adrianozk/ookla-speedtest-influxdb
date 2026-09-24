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

# Successful samples and status must be submitted together.
grep -F 'speedtest_status,host=cerberus success=1i,error_kind="none"' "$CAPTURE_FILE"

cat >"$TEST_ROOT/bin/speedtest" <<'EOF'
#!/bin/sh
case "${FAIL_MODE:-dns}" in
  dns) echo "Couldn't resolve host name" >&2; exit 1 ;;
  network) echo 'Network unreachable' >&2; exit 1 ;;
  timeout) exit 124 ;;
  parse) echo 'not json'; exit 0 ;;
esac
EOF
for mode in dns network timeout parse; do
    export FAIL_MODE="$mode"
    case "$mode" in
        dns) expected=dns ;;
        network) expected=network_unreachable ;;
        timeout) expected=timeout ;;
        parse) expected=invalid_result ;;
    esac
    if "$PROJECT_ROOT/scripts/collector.sh" >"$TEST_ROOT/log" 2>&1; then
        echo 'A failed test must keep its failure exit status' >&2
        exit 1
    fi
    grep -F "success=0i,error_kind=\"$expected\"" "$CAPTURE_FILE"
    if grep -F 'download_mbps=' "$CAPTURE_FILE"; then
        echo 'Failed tests must not contain speed measurements' >&2
        exit 1
    fi
done

# Database failure must be visible and retried without changing point identity.
cat >"$TEST_ROOT/bin/curl" <<'EOF'
#!/bin/sh
while [ "$#" -gt 0 ]; do
    if [ "$1" = "--data-binary" ]; then
        shift
        printf '%s\n' "$1" >>"$CAPTURE_FILE"
        exit 22
    fi
    shift
done
EOF
: >"$CAPTURE_FILE"
export FAIL_MODE=dns INFLUX_RETRIES=2 INFLUX_RETRY_INTERVAL=1
if "$PROJECT_ROOT/scripts/collector.sh" >"$TEST_ROOT/log" 2>&1; then
    exit 1
fi
test "$(wc -l <"$CAPTURE_FILE")" -eq 2
test "$(sort -u "$CAPTURE_FILE" | wc -l)" -eq 1
grep -F 'event=status_write_failed' "$TEST_ROOT/log"
echo 'status tests passed'
