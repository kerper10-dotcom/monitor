#!/usr/bin/env bash
# Drži ritam provjere. Ne otvara Njuskalo. Samo šalje workflow_dispatch.
# Svaka runda saved joba je svjezi ubuntu-latest runner, ~20 detaljnih URL-ova.
set -euo pipefail
cd "$(dirname "$0")/.."

queued_or_active() {
  local wf="$1"
  gh run list --workflow "$wf" --limit 40 --json status \
    --jq '[.[] | select(.status=="queued" or .status=="in_progress" or .status=="waiting" or .status=="pending" or .status=="requested")] | length'
}

queued_only() {
  local wf="$1"
  gh run list --workflow "$wf" --limit 40 --json status \
    --jq '[.[] | select(.status=="queued" or .status=="waiting" or .status=="pending" or .status=="requested")] | length'
}

dispatch_if_idle() {
  local wf="$1"
  local n
  n="$(queued_or_active "$wf")"
  if [ "$n" -gt 0 ]; then
    echo "skip ${wf} (${n} već aktivan)"
    return 0
  fi
  gh workflow run "$wf" --ref main
  echo "dispatched ${wf}"
}

# Ako watchdog stoji u redu iza nas, neka on preuzme. Inače dva pacera udvostruče scrape.
if [ "$(queued_only monitor-pace.yml)" -gt 0 ]; then
  echo "pace: drugi run već čeka, izlazim"
  exit 0
fi

count="$(python3 - <<'PY'
import sqlite3
print(sqlite3.connect("njuskalo.db").execute("select count(*) from saved_ads").fetchone()[0])
PY
)"
per=20
ticks=$(( (count + per - 1) / per ))
if [ "$ticks" -lt 1 ]; then
  ticks=1
fi
interval=$(( 3600 / ticks ))
if [ "$interval" -lt 180 ]; then
  interval=180
fi
fit=$(( 3600 / interval ))
if [ "$ticks" -gt "$fit" ]; then
  ticks=$fit
fi

echo "pace: ${count} oglasa, ${ticks} rundi, razmak ${interval}s"

for i in $(seq 1 "$ticks"); do
  dispatch_if_idle monitor-saved.yml
  if [ "$i" -eq 1 ]; then
    dispatch_if_idle monitor.yml
  fi
  echo "sleep ${interval}s (${i}/${ticks})"
  sleep "$interval"
done

if [ "$(queued_only monitor-pace.yml)" -eq 0 ]; then
  gh workflow run monitor-pace.yml --ref main
  echo "dispatched next pace"
else
  echo "sljedeći pace već čeka"
fi
