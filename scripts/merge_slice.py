"""Uspoji samo oglase iz slice_patch.json u zadnji main.

Osam jobova inače svaki napiše cijelu bazu iz starog checkouta i pregazi
cijene koje je prethodni job već spremio. Zato se ista obavijest vrti.

Blokade se samo dopisuju u captcha_log.json. Poruka ide jednom dnevno,
ne iz ovog joba.
"""
import json
import sqlite3
import subprocess
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

PATCH = Path("slice_patch.json")
CAPTCHA_PATCH = Path("captcha_patch.json")
JSON_PATH = Path("saved_ads.json")
DB_PATH = Path("njuskalo.db")
CAPTCHA_LOG = Path("captcha_log.json")
ZAGREB = ZoneInfo("Europe/Zagreb")


def _fetch() -> None:
    subprocess.check_call(["git", "fetch", "origin", "main"])


def _remote_captcha() -> dict:
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


def merge_ads() -> None:
    if not PATCH.exists():
        print("nema slice_patch.json")
        subprocess.check_call(
            ["git", "checkout", "origin/main", "--", "njuskalo.db", "saved_ads.json"]
        )
        return
    patch = {a["id"]: a for a in json.loads(PATCH.read_text(encoding="utf-8"))}
    if not patch:
        print("prazan patch")
        subprocess.check_call(
            ["git", "checkout", "origin/main", "--", "njuskalo.db", "saved_ads.json"]
        )
        return

    remote_raw = subprocess.check_output(["git", "show", "origin/main:saved_ads.json"])
    remote = {a["id"]: a for a in json.loads(remote_raw)}
    remote.update(patch)
    merged = sorted(remote.values(), key=lambda a: a["id"])
    JSON_PATH.write_text(json.dumps(merged, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    subprocess.check_call(["git", "checkout", "origin/main", "--", "njuskalo.db"])
    conn = sqlite3.connect(DB_PATH)
    for ad in patch.values():
        if conn.execute("SELECT 1 FROM saved_ads WHERE id = ?", (ad["id"],)).fetchone():
            conn.execute(
                "UPDATE saved_ads SET title = ?, url = ?, saved_price = ?, saved_date = ?, status = ? WHERE id = ?",
                (
                    ad.get("title"),
                    ad.get("url"),
                    ad.get("saved_price"),
                    ad.get("saved_date"),
                    ad.get("status") or "active",
                    ad["id"],
                ),
            )
        else:
            conn.execute(
                "INSERT INTO saved_ads (id, title, url, saved_price, saved_date, status) VALUES (?, ?, ?, ?, ?, ?)",
                (
                    ad["id"],
                    ad.get("title"),
                    ad.get("url"),
                    ad.get("saved_price"),
                    ad.get("saved_date"),
                    ad.get("status") or "active",
                ),
            )
    conn.commit()
    conn.close()
    print(f"merged {len(patch)} ads into {len(merged)}")


def merge_captcha() -> None:
    if not CAPTCHA_PATCH.exists():
        print("nema captcha_patch.json")
        return
    local = json.loads(CAPTCHA_PATCH.read_text(encoding="utf-8")).get("events") or []
    local = [
        {"id": int(ev["id"]), "at": str(ev["at"])}
        for ev in local
        if isinstance(ev, dict) and ev.get("id") is not None and ev.get("at")
    ]
    if not local:
        print("prazan captcha patch")
        return

    _fetch()
    remote = _remote_captcha()
    seen = {(ev["id"], ev["at"]) for ev in remote["events"]}
    events = list(remote["events"])
    for ev in local:
        key = (ev["id"], ev["at"])
        if key not in seen:
            events.append(ev)
            seen.add(key)

    cutoff = datetime.now(ZAGREB) - timedelta(hours=72)
    kept = []
    for ev in events:
        try:
            at = datetime.fromisoformat(ev["at"])
        except ValueError:
            continue
        if at.tzinfo is None:
            at = at.replace(tzinfo=ZAGREB)
        if at >= cutoff:
            kept.append(ev)
    kept.sort(key=lambda ev: (ev["at"], ev["id"]))
    CAPTCHA_LOG.write_text(
        json.dumps(
            {"last_digest": remote.get("last_digest"), "events": kept},
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    print(f"captcha log: +{len(local)} this run, {len(kept)} kept")


def main() -> None:
    _fetch()
    merge_ads()
    merge_captcha()


if __name__ == "__main__":
    main()
