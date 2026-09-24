# Collection status and log import

[Português (Brasil)](status-history.pt-BR.md)

The collector writes a separate `${MEASUREMENT}_status` measurement (default:
`speedtest_status`) to the same bucket as speed measurements. The importable
dashboard displays these states. Each completed attempt has `success=1i` or
`success=0i`, `error_kind`, `error_detail`, and `server_id` (a string field with
the requested server, or `automatic`). The `host` tag matches the installation's
`HOST_TAG`. Timestamps record attempt completion in UTC, with second precision.

New collections also record `interval_seconds`, `fail_interval_seconds`, and
`timeout_seconds`. Intervals are waits after execution and write attempts,
not fixed wall-clock schedules. These fields are not invented when importing
historical logs.

- `none`: successful test.
- `dns`: hostname resolution failure.
- `network_unreachable`: unreachable network.
- `timeout`: process exited with code 124 or 137 (timeout/interruption).
- `invalid_result`: error converting the result JSON.
- `speedtest_error`: other failures.

A successful test does not imply a successful database write. Writes use the
existing `INFLUX_RETRIES` setting. If InfluxDB is also unavailable, the collector
logs the write failure; there is no persistent retry queue. Retain logs for later
import. Missing status means unknown, not proof of an internet outage. Failed
tests do not write zero speeds.

## Import history

Run on the Docker host with Python 3 installed. Python is not required inside
the container. Use logs from **one collector** per run. The script accepts
output with or without the extra timestamps added by `docker logs`.

Save logs as `speedtest.log`, or export them (adjust the example time range):

```bash
docker logs --since '2026-09-24T11:30:00Z' --until '2026-09-24T20:30:00Z' ookla-speedtest-influxdb > speedtest.log 2>&1
```

From the repository directory, obtain the container's host tag:

```bash
STATUS_HOST=$(docker exec ookla-speedtest-influxdb sh -c 'printf "%s" "${HOST_TAG:-$(hostname)}"')
```

If the tag changed since the incident, use its historical value. If `MEASUREMENT`
is not `speedtest`, add `--measurement VALUE` to both commands below.

First preview the conversion without writing to the database:

```bash
python3 scripts/import-status-logs.py speedtest.log --host "$STATUS_HOST" --output status-history.lp
```

Then import using the existing container's network and credentials:

```bash
python3 scripts/import-status-logs.py speedtest.log --host "$STATUS_HOST" --container ookla-speedtest-influxdb --write
```

The old container already includes curl and jq, so importing works before
updating the collector. No token needs to be pasted into the terminal. Without
`--container`, `--write` uses INFLUX_URL, INFLUX_ORG, INFLUX_BUCKET, and INFLUX_TOKEN
from the local environment (a `.env` file is not loaded automatically).

Successes mark the state before an incident and its recovery without reimporting
speed metrics. Use `--failures-only` to import errors only.

The importer uses the collector's outer UTC timestamp, not the local timestamp
embedded in error details. Repeating the same file with the same host and
measurement updates the same points without duplicates. Bucket retention and
token write permissions must allow the imported timestamps. On an HTTP error,
check the message: the server may have accepted part of the batch; correcting
the problem and repeating the same file is safe. Old logs do not reliably
identify timeout exit codes.

## Use in Grafana

Query `speedtest_status`, filter the `host` tag, and select the `success` field:
1 means success, 0 means failure. `error_kind` and `error_detail` provide the
reason. Periods without points mean unknown/no data. Do not fill missing speeds
with zero or calculate time-based availability from the fraction of successful
attempts: collection frequency changes after a failure.

## Deploy the collector

After merging the change and publishing the updated image, run from the Compose
directory:

```bash
docker compose pull speedtest-influxdb
docker compose up -d speedtest-influxdb
```

Until the image is published, `latest` still contains the previous version.

## Import the updated dashboard

Use the existing [`grafana/dashboard.json`](../grafana/dashboard.json) from this
branch. Import the updated JSON in Grafana and select the InfluxDB (Flux) data
source, Bucket, and Host. The original v2 dashboard format is preserved. Gap
queries require Flux 0.179+ (`internal/debug.null`, available in InfluxDB 2.7).

Set **Max data age (seconds)** to `1200` for tests every 15 minutes, or keep
`4500` for hourly tests. This is a manual limit including execution/retry margin;
it is not inferred from historical logs.

- Latest attempt shows success, failure, or stale data; missing status is unknown.
- Age of last successful test shows the age of the latest measurement in range.
- The four original cards show recent measurements only, labeled as last successful results.
- Collection attempts shows green/red dots without interpolating unknown periods.
- Failed attempts — details lists up to 500 failures with their reasons.
- History charts preserve individual points and break lines at recorded failures
  or gaps longer than the configured limit, without inventing zero speeds.

Age is relative to the end of the selected range, allowing historical incident
review. Queries only use data inside that range. For long ranges or frequent
collections, reduce the displayed range: history is not aggregated to avoid
hiding short failures. Import historical logs before viewing historical status.
You do not need to wait for the merge to import the dashboard.

The three status panels are grouped in **Collection status**, collapsed by default. **Recent tests** combines successful measurements and failed attempts (Status/Reason), newest first, with no fabricated speeds or duplicated success records. Full error details remain in the separate table.
