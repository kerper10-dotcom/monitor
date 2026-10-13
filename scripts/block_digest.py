#!/usr/bin/env python3
"""Jednom dnevno pošalje koliko je Njuškalo blokirao spremljene oglase."""
import json
import os
import subprocess
import sys
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

import requests

LOG = Path("captcha_log.json")
ZAGREB = ZoneInfo("Europe/Zagreb")
QUIET_HOURS = 20
KEEP_HOURS = 72


def now() -> datetime:
    return datetime.now(ZAGREB)


def parse_at(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        at = datetime.fromisoformat(value)
    except ValueError:
        return None
    if at.tzinfo is None:
        at = at.replace(tzinfo=ZAGREB)
    return at


def oglas_word(n: int) -> str:
    if n % 10 == 1 and n % 100 != 11:
        return "oglas"
    return "oglasa"


def put_word(n: int) -> str:
    if n % 10 == 1 and n % 100 != 11:
        return "put"
    return "puta"


def digest_text(n_ads: int, n_times: int, last: datetime | None, current: datetime) -> str:
    if last is None or (current - last) <= timedelta(hours=30):
        when = "U proteklih 24 sata"
    else:
        when = f"Od {last.astimezone(ZAGREB).strftime('%d.%m.%Y. %H:%M')}"
    return (
        f"{when} Njuškalo je blokirao {n_ads} {oglas_word(n_ads)} "
        f"{n_times} {put_word(n_times)}."
    )


def load_remote() -> dict:
    subprocess.check_call(["git", "fetch", "origin", "main"])
    try:
        raw = subprocess.check_output(
            ["git", "show", "origin/main:captcha_log.json"],
            stderr=subprocess.DEVNULL,
        )
        data = json.loads(raw)
    except (subprocess.CalledProcessError, json.JSONDecodeError):
        data = {}
    if not isinstance(data, dict):
        data = {}
    events = []
    for ev in data.get("events") or []:
        if isinstance(ev, dict) and ev.get("id") is not None and ev.get("at"):
            events.append({"id": int(ev["id"]), "at": str(ev["at"])})
    return {"last_digest": data.get("last_digest"), "events": events}


def send(text: str) -> None:
    token = os.environ.get("TELEGRAM_BOT_TOKEN", "")
    chat = os.environ.get("TELEGRAM_CHAT_ID", "")
    if not token or not chat:
        raise SystemExit("Telegram nije konfiguriran")
    resp = requests.post(
        f"https://api.telegram.org/bot{token}/sendMessage",
        json={
            "chat_id": chat,
            "text": text,
            "disable_web_page_preview": True,
        },
        timeout=15,
    )
    if resp.status_code != 200:
        raise SystemExit(f"Telegram error {resp.status_code}: {resp.text[:200]}")
    print(f"poslano: {text}")


def write_and_push(payload: dict) -> bool:
    LOG.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    subprocess.check_call(["git", "add", "captcha_log.json"])
    if subprocess.call(["git", "diff", "--staged", "--quiet"]) == 0:
        print("nema promjene za commit")
        return True
    subprocess.check_call(
        ["git", "commit", "-m", "Record daily Njuskalo block digest [skip ci]"]
    )
    return subprocess.call(["git", "push", "origin", "HEAD:main"]) == 0


def main() -> None:
    reported: set[tuple[int, str]] = set()
    sent = False
    for attempt in range(3):
        data = load_remote()
        current = now()
        last = parse_at(data.get("last_digest"))
        if last and (current - last).total_seconds() < QUIET_HOURS * 3600:
            print("sazetak je vec isao u zadnjih 20 h")
            return

        pending = []
        for ev in data["events"]:
            at = parse_at(ev["at"])
            if at is None:
                continue
            if (ev["id"], ev["at"]) in reported:
                continue
            pending.append(ev)

        if pending and not sent:
            n_times = len(pending)
            n_ads = len({ev["id"] for ev in pending})
            send(digest_text(n_ads, n_times, last, current))
            reported = {(ev["id"], ev["at"]) for ev in pending}
            sent = True
        elif not pending and not sent:
            print("nema blokada, bez poruke")

        fresh = load_remote()
        fresh_last = parse_at(fresh.get("last_digest"))
        if (
            fresh_last
            and (current - fresh_last).total_seconds() < QUIET_HOURS * 3600
            and not sent
        ):
            print("sazetak je vec isao u zadnjih 20 h")
            return

        cutoff = current - timedelta(hours=KEEP_HOURS)
        kept = []
        for ev in fresh["events"]:
            at = parse_at(ev["at"])
            if at is None or at < cutoff:
                continue
            if (ev["id"], ev["at"]) in reported:
                continue
            kept.append(ev)
        payload = {
            "last_digest": current.isoformat(timespec="seconds"),
            "events": kept,
        }
        if write_and_push(payload):
            print(f"spremljeno, ostalo {len(kept)} nezabiljezenih")
            return
        print(f"push nije prosao, pokusaj {attempt + 1}")
        subprocess.check_call(["git", "fetch", "origin", "main"])
        subprocess.check_call(["git", "reset", "--hard", "origin/main"])
    raise SystemExit("nije uspio push sazetka")


if __name__ == "__main__":
    sys.exit(main())
