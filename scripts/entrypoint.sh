#!/bin/sh

set -eu

log() {
    printf '%s level=%s event=%s %s\n' \
        "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$1" "$2" "${3:-}"
}

if [ "${OOKLA_EULA_ACCEPTED:-false}" != "true" ]; then
    log ERROR license_not_accepted \
        'set OOKLA_EULA_ACCEPTED=true after reviewing https://www.speedtest.net/about/eula'
    exit 2
fi

if ! command -v speedtest >/dev/null 2>&1; then
    log INFO speedtest_install_started 'source=packagecloud.io/ookla/speedtest-cli'

    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://packagecloud.io/ookla/speedtest-cli/gpgkey \
        | gpg --batch --yes --dearmor -o /etc/apt/keyrings/ookla-speedtest-cli.gpg

    printf '%s\n' \
        'deb [signed-by=/etc/apt/keyrings/ookla-speedtest-cli.gpg] https://packagecloud.io/ookla/speedtest-cli/debian/ bookworm main' \
        > /etc/apt/sources.list.d/ookla-speedtest-cli.list

    apt-get update
    apt-get install -y --no-install-recommends speedtest
    rm -rf /var/lib/apt/lists/*

    log INFO speedtest_install_succeeded "version=$(speedtest --version | head -n 1)"
fi

exec gosu collector /app/scripts/collector.sh
