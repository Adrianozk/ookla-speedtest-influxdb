#!/usr/bin/env python3
"""Convert collector logs into status points. Preview by default; --write opts in."""
import argparse
from collections import Counter
from datetime import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

EVENT = re.compile(r'(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ) level=\w+ event=(\w+)(?: (.*))?$')


def escape(value):
    for old, new in [('\\', '\\\\'), (' ', '\\ '), (',', '\\,'), ('=', '\\=')]:
        value = value.replace(old, new)
    return value


def string(value):
    return json.dumps(value, ensure_ascii=False)


def convert(text, host, measurement='speedtest', failures_only=False):
    points = {}
    server = 'unknown'
    counts = Counter()
    for line in text.splitlines():
        match = EVENT.search(line.strip())
        if not match:
            continue
        stamp, event, rest = match.groups()
        rest = rest or ''
        if event == 'speedtest_started':
            found = re.search(r'(?:^| )server_id=(\S+)', rest)
            server = found.group(1) if found else 'unknown'
        if event not in ('speedtest_succeeded', 'speedtest_failed', 'speedtest_parse_failed'):
            continue
        success = event == 'speedtest_succeeded'
        if success and failures_only:
            continue
        detail = rest.partition('detail=')[2] if not success else ''
        kind = 'none' if success else 'speedtest_error'
        if event == 'speedtest_parse_failed':
            kind = 'invalid_result'
        elif "Couldn't resolve host name" in detail:
            kind = 'dns'
        elif 'Network unreachable' in detail:
            kind = 'network_unreachable'
        # Old logs do not reliably identify timeout exit codes. Do not infer them.
        epoch = int(datetime.fromisoformat(stamp.replace('Z', '+00:00')).timestamp())
        fields = f'success={int(success)}i,error_kind={string(kind)},error_detail={string(detail)},server_id={string(server)}'
        point = f'{escape(measurement + "_status")},host={escape(host)} {fields} {epoch}'
        if epoch in points and points[epoch] != point:
            raise ValueError(f'Conflicting events at {stamp}; use logs from one collector only')
        if epoch not in points:
            counts[kind] += 1
        points[epoch] = point
    return '\n'.join(points[t] for t in sorted(points)) + ('\n' if points else ''), counts


CONTAINER_WRITE = '''set -eu
: "${INFLUX_URL:?}" "${INFLUX_ORG:?}" "${INFLUX_BUCKET:?}" "${INFLUX_TOKEN:?}"
org=$(printf '%s' "$INFLUX_ORG" | jq -sRr '@uri')
bucket=$(printf '%s' "$INFLUX_BUCKET" | jq -sRr '@uri')
curl --fail-with-body --silent --show-error --connect-timeout 10 --max-time 60 \
  -X POST -H "Authorization: Token $INFLUX_TOKEN" -H 'Content-Type: text/plain; charset=utf-8' \
  --data-binary @- "${INFLUX_URL%/}/api/v2/write?org=$org&bucket=$bucket&precision=s"
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('logfile', type=Path)
    parser.add_argument('--host', required=True, help='Exact HOST_TAG used by this collector')
    parser.add_argument('--measurement', default='speedtest', help='Existing base MEASUREMENT (status suffix added)')
    parser.add_argument('--failures-only', action='store_true')
    parser.add_argument('--output', type=Path, help='Also save line protocol for review')
    parser.add_argument('--write', action='store_true', help='Write to InfluxDB; otherwise only preview')
    parser.add_argument('--container', help='Use an existing collector container and its Influx credentials/network')
    args = parser.parse_args()
    if any(c in args.host + args.measurement for c in '\r\n'):
        parser.error('Host and measurement must be single-line values')
    payload, counts = convert(args.logfile.read_text(encoding='utf-8-sig'), args.host, args.measurement, args.failures_only)
    if not payload:
        parser.error('No matching result events found; nothing written')
    print(f'{sum(counts.values())} points: {dict(counts)}', file=sys.stderr)
    if args.output:
        args.output.write_text(payload, encoding='utf-8')
    if not args.write:
        if not args.output:
            print(payload, end='')
        print('Preview only. Use --write to import.', file=sys.stderr)
        return
    if args.container:
        subprocess.run(['docker', 'exec', '-i', args.container, 'sh', '-c', CONTAINER_WRITE], input=payload.encode(), check=True)
    else:
        config = {key: os.environ[key] for key in ('INFLUX_URL', 'INFLUX_ORG', 'INFLUX_BUCKET', 'INFLUX_TOKEN')}
        query = urllib.parse.urlencode({'org': config['INFLUX_ORG'], 'bucket': config['INFLUX_BUCKET'], 'precision': 's'})
        req = urllib.request.Request(config['INFLUX_URL'].rstrip('/') + '/api/v2/write?' + query, data=payload.encode(), headers={'Authorization': 'Token ' + config['INFLUX_TOKEN'], 'Content-Type': 'text/plain; charset=utf-8'}, method='POST')
        with urllib.request.urlopen(req, timeout=60) as response:
            if response.status != 204:
                raise ValueError(f'Unexpected HTTP status: {response.status}')
    print('Import completed.', file=sys.stderr)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as exc:
        print(f'Import failed: {exc}', file=sys.stderr)
        sys.exit(1)
