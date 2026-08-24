#!/usr/bin/env bash
# Daily Workers KV operation counts vs the free-tier caps.
#
# Cloudflare's "you've used 50% of the daily limit" emails are batched, not sent
# on the crossing -- a threshold hit at midday has arrived at 2am the next
# morning -- and they don't say WHICH limit. This does both.
#
# Needs a Cloudflare API token with Account Analytics: Read.
#   CLOUDFLARE_API_TOKEN env var, or the system keyring (see below).
#
# Usage:
#   ./scripts/kv-usage.sh            # last 7 days
#   ./scripts/kv-usage.sh 14         # last 14 days
#   ./scripts/kv-usage.sh 1 hourly   # today, hour by hour
set -euo pipefail

ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-4381c9721857ce9ee9ac0c5e4429af7e}"
DAYS="${1:-7}"
MODE="${2:-daily}"

TOKEN="${CLOUDFLARE_API_TOKEN:-}"
if [[ -z $TOKEN ]] && command -v secret-tool >/dev/null 2>&1; then
    TOKEN="$(secret-tool lookup service cloudflare account api-token 2>/dev/null || true)"
fi
if [[ -z $TOKEN ]]; then
    echo "No API token. Set CLOUDFLARE_API_TOKEN, or store one with:" >&2
    echo "  printf '%s' \"\$TOKEN\" | secret-tool store --label='Cloudflare API token' service cloudflare account api-token" >&2
    exit 1
fi

if [[ $MODE == hourly ]]; then
    FROM="$(date -u -d "today 00:00" +%Y-%m-%dT%H:%M:%SZ)"
    FILTER="datetimeHour_geq: \\\"$FROM\\\""
    DIMS="actionType datetimeHour"
else
    FROM="$(date -u -d "$DAYS days ago" +%Y-%m-%d)"
    FILTER="date_geq: \\\"$FROM\\\""
    DIMS="actionType date"
fi

curl -s https://api.cloudflare.com/client/v4/graphql \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"query\":\"query { viewer { accounts(filter: {accountTag: \\\"$ACCOUNT_ID\\\"}) { kvOperationsAdaptiveGroups(filter: {$FILTER}, limit: 1000) { sum { requests } dimensions { $DIMS } } } } }\"}" \
| python3 -c '
import json, sys
# Free tier, per UTC day. Exceeding a cap means 429s from the KV API and
# failing operations inside the Worker -- not throttling, hard failure.
CAPS = {"read": 100_000, "write": 1_000, "list": 1_000, "delete": 1_000}
payload = json.load(sys.stdin)
if payload.get("errors"):
    sys.exit("API error: " + json.dumps(payload["errors"]))
rows = payload["data"]["viewer"]["accounts"][0]["kvOperationsAdaptiveGroups"]
if not rows:
    sys.exit("no data in range")
key = "datetimeHour" if "datetimeHour" in rows[0]["dimensions"] else "date"
buckets = {}
for r in rows:
    buckets.setdefault(r["dimensions"][key], {})[r["dimensions"]["actionType"]] = r["sum"]["requests"]
hourly = key == "datetimeHour"
label = "hour" if hourly else "date"
print(f"{label:18s} " + "".join(f"{a:>9s} {a[0]+chr(37):>6s}" for a in CAPS))
run = {a: 0 for a in CAPS}
for b in sorted(buckets):
    v = buckets[b]
    cells = ""
    for a, cap in CAPS.items():
        n = v.get(a, 0)
        run[a] += n
        shown = run[a] if hourly else n     # hourly view accumulates toward the daily cap
        pct = shown * 100 / cap
        cells += f"{shown:9d} {pct:5.0f}%" + ("!" if pct >= 100 else " " if pct < 50 else "*")
    print(f"{b[:16]:18s}{cells}")
print("\n  * at or past 50% of the daily cap   ! over cap: KV returns 429 and Worker ops fail")
'
