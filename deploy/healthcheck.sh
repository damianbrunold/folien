#!/bin/sh
# Health probe for folien, run every minute by
# folien-health.service: GET /healthz on the host/port from the
# config. Two strikes: on failure wait 5s and probe again; only then restart
# the unit, so one slow request cannot bounce the daemon.
#
# Usage: healthcheck.sh <config.scm> <unit>
conf=$1
unit=$2

# The string or number of a (define name value) line in the config.
value() {
  sed -n "s/^[[:space:]]*(define[[:space:]][[:space:]]*$1[[:space:]][[:space:]]*\"\{0,1\}\([^\" )]*\).*/\1/p" "$conf" | head -n 1
}

port=$(value http-port)
host=$(value http-host)
case "$host" in ''|0.0.0.0|::) host=127.0.0.1 ;; esac
url="http://$host:${port:-8090}/healthz"

probe() { curl -fsS --max-time 5 "$url" >/dev/null; }

if ! probe; then
  sleep 5
  if ! probe; then
    echo "$unit: $url failed twice; restarting"
    systemctl restart "$unit"
  fi
fi
