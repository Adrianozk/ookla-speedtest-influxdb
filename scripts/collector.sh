#!/usr/bin/env bash

set -eu

log() {
    level="$1"
    event="$2"
    shift 2
    timestamp="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    printf '%s level=%s event=%s' "$timestamp" "$level" "$event"
    if [ "$#" -gt 0 ]; then
        printf ' %s' "$*"
    fi
    printf '\n'
}

require_env() {
    name="$1"
    value="$(printenv "$name" 2>/dev/null || true)"
    if [ -z "$value" ]; then
        log ERROR configuration_error "missing=$name"
        exit 2
    fi
}

is_positive_integer() {
    case "$1" in
        ''|*[!0-9]*|0) return 1 ;;
        *) return 0 ;;
    esac
}

urlencode() {
    printf '%s' "$1" | jq -sRr '@uri'
}

make_line_protocol() {
    jq -er \
        --arg host "$HOST_TAG" \
        --arg measurement "$MEASUREMENT" '
        def tag_escape:
            tostring
            | gsub("\\\\"; "\\\\\\\\")
            | gsub(" "; "\\ ")
            | gsub(","; "\\,")
            | gsub("="; "\\=");

        def field_values:
            [
                "download_mbps=\((.download.bandwidth * 8 / 1000000))",
                "upload_mbps=\((.upload.bandwidth * 8 / 1000000))",
                "latency_ms=\(.ping.latency)",
                "jitter_ms=\(.ping.jitter)",
                "download_bytes=\(.download.bytes)i",
                "upload_bytes=\(.upload.bytes)i",
                "download_elapsed_ms=\(.download.elapsed)i",
                "upload_elapsed_ms=\(.upload.elapsed)i",
                (if .packetLoss != null then "packet_loss_pct=\(.packetLoss)" else empty end)
            ] | join(",");

        def tag_values:
            [
                "host=\($host | tag_escape)",
                "server_id=\(.server.id | tag_escape)",
                "server_name=\(.server.name | tag_escape)",
                "server_location=\(.server.location | tag_escape)",
                "server_country=\(.server.country | tag_escape)",
                "isp=\(.isp | tag_escape)",
                "interface=\(.interface.name | tag_escape)"
            ] | join(",");

        "\($measurement | tag_escape),\(tag_values) \(field_values) \(.timestamp | fromdateiso8601)"
    '
}

run_speedtest() {
    result_file="$1"
    error_file="$2"

    set -- speedtest \
        --accept-license \
        --accept-gdpr \
        --format=json

    if [ -n "$SPEEDTEST_SERVER_ID" ]; then
        set -- "$@" "--server-id=$SPEEDTEST_SERVER_ID"
    fi

    timeout "${SPEEDTEST_TIMEOUT}s" "$@" >"$result_file" 2>"$error_file"
}

write_to_influx() {
    line="$1"
    org="$(urlencode "$INFLUX_ORG")"
    bucket="$(urlencode "$INFLUX_BUCKET")"
    url="${INFLUX_URL%/}/api/v2/write?org=$org&bucket=$bucket&precision=s"

    curl \
        --fail-with-body \
        --silent \
        --show-error \
        --connect-timeout "$INFLUX_CONNECT_TIMEOUT" \
        --max-time "$INFLUX_WRITE_TIMEOUT" \
        --request POST \
        --header "Authorization: Token $INFLUX_TOKEN" \
        --header "Content-Type: text/plain; charset=utf-8" \
        --data-binary "$line" \
        "$url" >/dev/null
}

# Status uses a separate measurement; failed tests never become zero Mbps.
make_status_line() {
    local success="$1" kind="$2" detail="$3" epoch="$4"
    jq -nr --arg measurement "${MEASUREMENT}_status" --arg host "$HOST_TAG" \
        --arg server "${SPEEDTEST_SERVER_ID:-automatic}" \
        --arg kind "$kind" --arg detail "$detail" --arg epoch "$epoch" \
        --argjson success "$success" --argjson interval "$SPEEDTEST_INTERVAL" \
        --argjson fail_interval "$SPEEDTEST_FAIL_INTERVAL" \
        --argjson timeout "$SPEEDTEST_TIMEOUT" '
        def esc: gsub("\\\\"; "\\\\\\\\") | gsub(" "; "\\ ") | gsub(","; "\\,") | gsub("="; "\\=");
        "\($measurement | esc),host=\($host | esc) success=\($success)i,error_kind=\($kind | tojson),error_detail=\($detail | tojson),server_id=\($server | tojson),interval_seconds=\($interval)i,fail_interval_seconds=\($fail_interval)i,timeout_seconds=\($timeout)i \($epoch)"
    '
}

classify_error() {
    case "$1" in
        124|137) printf timeout ;;
        *) case "$2" in
            *"Couldn't resolve host name"*) printf dns ;;
            *"Network unreachable"*) printf network_unreachable ;;
            *) printf speedtest_error ;;
        esac ;;
    esac
}

write_with_retries() {
    local line="$1" attempt
    attempt=1
    while [ "$attempt" -le "$INFLUX_RETRIES" ]; do
        if write_to_influx "$line"; then
            log INFO influx_write_succeeded "bucket=$INFLUX_BUCKET attempt=$attempt"
            return 0
        fi

        log WARN influx_write_failed "bucket=$INFLUX_BUCKET attempt=$attempt"
        if [ "$attempt" -lt "$INFLUX_RETRIES" ]; then
            sleep "$INFLUX_RETRY_INTERVAL"
        fi
        attempt=$((attempt + 1))
    done

    return 1
}

collect_once() {
    tmp_dir="$(mktemp -d)"
    result_file="$tmp_dir/result.json"
    error_file="$tmp_dir/speedtest.stderr"

    log INFO speedtest_started "server_id=${SPEEDTEST_SERVER_ID:-automatic}"

    if run_speedtest "$result_file" "$error_file"; then
        :
    else
        exit_code=$?
        detail="$(tr '\n' ' ' <"$error_file" | cut -c1-500)"
        log ERROR speedtest_failed "detail=${detail:-unknown}"
        status_epoch="$(date -u -d "$timestamp" +%s)"
        status_line="$(make_status_line 0 "$(classify_error "$exit_code" "$detail")" "${detail:-unknown}" "$status_epoch")"
        write_with_retries "$status_line" || log ERROR status_write_failed
        rm -rf "$tmp_dir"
        return 1
    fi

    if ! line="$(make_line_protocol <"$result_file")"; then
        log ERROR speedtest_parse_failed "detail=invalid_or_incomplete_json"
        status_line="$(make_status_line 0 invalid_result invalid_or_incomplete_json "$(date -u -d "$timestamp" +%s)")"
        write_with_retries "$status_line" || log ERROR status_write_failed
        rm -rf "$tmp_dir"
        return 1
    fi

    summary="$(jq -r '
        "download_mbps=\(.download.bandwidth * 8 / 1000000) " +
        "upload_mbps=\(.upload.bandwidth * 8 / 1000000) " +
        "latency_ms=\(.ping.latency) server_id=\(.server.id)"
    ' "$result_file")"
    log INFO speedtest_succeeded "$summary"

    status_line="$(make_status_line 1 none '' "$(date -u -d "$timestamp" +%s)")"
    if write_with_retries "$line
$status_line"; then
        rm -rf "$tmp_dir"
        return 0
    fi

    rm -rf "$tmp_dir"
    return 1
}

for name in INFLUX_URL INFLUX_ORG INFLUX_BUCKET INFLUX_TOKEN; do
    require_env "$name"
done

SPEEDTEST_SERVER_ID="${SPEEDTEST_SERVER_ID:-}"
SPEEDTEST_INTERVAL="${SPEEDTEST_INTERVAL:-3600}"
SPEEDTEST_FAIL_INTERVAL="${SPEEDTEST_FAIL_INTERVAL:-300}"
SPEEDTEST_TIMEOUT="${SPEEDTEST_TIMEOUT:-180}"
INFLUX_RETRIES="${INFLUX_RETRIES:-3}"
INFLUX_RETRY_INTERVAL="${INFLUX_RETRY_INTERVAL:-10}"
INFLUX_CONNECT_TIMEOUT="${INFLUX_CONNECT_TIMEOUT:-10}"
INFLUX_WRITE_TIMEOUT="${INFLUX_WRITE_TIMEOUT:-30}"
RUN_ONCE="${RUN_ONCE:-false}"
MEASUREMENT="${MEASUREMENT:-speedtest}"
HOST_TAG="${HOST_TAG:-$(hostname)}"

for value in \
    "$SPEEDTEST_INTERVAL" \
    "$SPEEDTEST_FAIL_INTERVAL" \
    "$SPEEDTEST_TIMEOUT" \
    "$INFLUX_RETRIES" \
    "$INFLUX_RETRY_INTERVAL" \
    "$INFLUX_CONNECT_TIMEOUT" \
    "$INFLUX_WRITE_TIMEOUT"; do
    if ! is_positive_integer "$value"; then
        log ERROR configuration_error "detail=intervals_timeouts_and_retries_must_be_positive_integers"
        exit 2
    fi
done

log INFO collector_started \
    "host=$HOST_TAG interval_seconds=$SPEEDTEST_INTERVAL server_id=${SPEEDTEST_SERVER_ID:-automatic}"

while :; do
    if collect_once; then
        status=0
        delay="$SPEEDTEST_INTERVAL"
    else
        status=1
        delay="$SPEEDTEST_FAIL_INTERVAL"
    fi

    if [ "$RUN_ONCE" = "true" ]; then
        exit "$status"
    fi

    log INFO next_run_scheduled "seconds=$delay"
    sleep "$delay"
done
