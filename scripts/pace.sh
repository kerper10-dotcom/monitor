#!/usr/bin/env bash
# Drži ritam samo dok runda prođe bez CAPTCHA-e.
# Ne otvara Njuskalo. Ako je runner blokiran, stane nakon te jedne runde.
set -euo pipefail
cd "$(dirname "$0")/.."

queued_only() {
  gh run list --workflow monitor-pace.yml --limit 40 --json status \
    --jq '[.[] | select(.status=="queued" or .status=="waiting" or .status=="pending" or .status=="requested")] | length'
}

if [ "$(queued_only)" -gt 0 ]; then
  echo "pace: drugi run vec ceka, izlazim"
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
echo "pace: ${count} oglasa, najvise ${ticks} rundi, stajem na prvoj CAPTCHA-i"

for i in $(seq 1 "$ticks"); do
  set +e
  line="$(python3 scripts/pace_once.py monitor-saved.yml)"
  rc=$?
  set -e
  echo "pace tick ${i}/${ticks} rc=${rc} ${line}"
  if [ "$rc" -eq 10 ]; then
    echo "pace: CAPTCHA, ne nastavljam. Iduci pokusaj je iduci watchdog."
    exit 0
  fi
  if [ "$rc" -ne 0 ]; then
    echo "pace: runda nije uspjela"
    exit "$rc"
  fi
  if [ "$i" -lt "$ticks" ]; then
    echo "sleep 120"
    sleep 120
  fi
done

if [ "$(queued_only)" -eq 0 ]; then
  gh workflow run monitor-pace.yml --ref main
  echo "dispatched next pace"
else
  echo "sljedeci pace vec ceka"
fi
