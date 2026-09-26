"""Uspoji samo oglase iz slice_patch.json u zadnji main.

Osam jobova inače svaki napiše cijelu bazu iz starog checkouta i pregazi
cijene koje je prethodni job već spremio. Zato se ista obavijest vrti.
"""
import json
import sqlite3
import subprocess
from pathlib import Path

PATCH = Path("slice_patch.json")
JSON_PATH = Path("saved_ads.json")
DB_PATH = Path("njuskalo.db")


def main() -> None:
    if not PATCH.exists():
        print("nema slice_patch.json")
        return
    patch = {a["id"]: a for a in json.loads(PATCH.read_text(encoding="utf-8"))}
    if not patch:
        print("prazan patch")
        return

    subprocess.check_call(["git", "fetch", "origin", "main"])
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


if __name__ == "__main__":
    main()
