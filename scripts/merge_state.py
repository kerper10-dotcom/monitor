#!/usr/bin/env python3
"""Spoji dva njuskalo.db nakon rebase konflikta.

GitHub saved i category job znaju u isto vrijeme commitati isti sqlite.
Binarni rebase se ne da spojiti sam. Ova skripta:
  - za svaki spremljeni oglas zadrži noviji last_attempt / last_checked
  - unija notified_events (da se ista obavijest ne pošalje dvaput)
  - unija seen_ads
Zatim ponovo napiše saved_ads.json iz spojene baze.
"""

import json
import shutil
import sqlite3
import subprocess
import sys
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DB_NAME = "njuskalo.db"
JSON_NAME = "saved_ads.json"


def _parse(value) -> datetime:
    if not value:
        return datetime.min
    for fmt in ("%d.%m.%Y. %H:%M", "%d.%m.%Y %H:%M", "%d.%m.%Y"):
        try:
            return datetime.strptime(str(value).strip(), fmt)
        except ValueError:
            continue
    return datetime.min


def _stamp(row: dict) -> datetime:
    return max(_parse(row.get("last_attempt")), _parse(row.get("last_checked")))


def _cols(conn: sqlite3.Connection, table: str) -> list[str]:
    return [r[1] for r in conn.execute(f"PRAGMA table_info({table})")]


def _saved_map(conn: sqlite3.Connection) -> dict[int, dict]:
    cols = _cols(conn, "saved_ads")
    out = {}
    for rec in conn.execute(f"SELECT {', '.join(cols)} FROM saved_ads"):
        row = dict(zip(cols, rec))
        out[int(row["id"])] = row
    return out


def _prefer(a: dict | None, b: dict | None) -> dict:
    if a is None:
        return dict(b)
    if b is None:
        return dict(a)
    winner, other = (b, a) if _stamp(b) > _stamp(a) else (a, b)
    merged = dict(winner)
    for key, value in other.items():
        if merged.get(key) in (None, "") and value not in (None, ""):
            merged[key] = value
    return merged


def _ensure_saved_schema(conn: sqlite3.Connection) -> None:
    cols = set(_cols(conn, "saved_ads"))
    if "status" not in cols:
        conn.execute("ALTER TABLE saved_ads ADD COLUMN status TEXT DEFAULT 'active'")
    if "last_attempt" not in cols:
        conn.execute("ALTER TABLE saved_ads ADD COLUMN last_attempt TEXT")


def _union_simple(dst: sqlite3.Connection, src: sqlite3.Connection, table: str) -> None:
    src_tables = {r[0] for r in src.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    dst_tables = {r[0] for r in dst.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    if table not in src_tables or table not in dst_tables:
        return
    cols = [c for c in _cols(src, table) if c in set(_cols(dst, table))]
    if not cols:
        return
    listed = ", ".join(cols)
    placeholders = ", ".join("?" for _ in cols)
    rows = src.execute(f"SELECT {listed} FROM {table}").fetchall()
    dst.executemany(
        f"INSERT OR IGNORE INTO {table} ({listed}) VALUES ({placeholders})",
        rows,
    )


def merge_databases(path_a: Path, path_b: Path, dest: Path) -> None:
    """Spoji A i B u dest. Noviji redak spremljenog oglasa pobjeđuje."""
    staging = dest.with_suffix(".merge-tmp")
    shutil.copy(path_a, staging)
    dst = sqlite3.connect(staging)
    src = sqlite3.connect(path_b)
    try:
        _ensure_saved_schema(dst)
        _ensure_saved_schema(src)
        combined = _saved_map(dst)
        for ad_id, row in _saved_map(src).items():
            combined[ad_id] = _prefer(combined.get(ad_id), row)

        dst.execute("DELETE FROM saved_ads")
        cols = _cols(dst, "saved_ads")
        placeholders = ", ".join("?" for _ in cols)
        dst.executemany(
            f"INSERT INTO saved_ads ({', '.join(cols)}) VALUES ({placeholders})",
            [tuple(row.get(c) for c in cols) for row in combined.values()],
        )
        _union_simple(dst, src, "notified_events")
        _union_simple(dst, src, "seen_ads")
        dst.commit()
    finally:
        dst.close()
        src.close()
    staging.replace(dest)


def export_saved_json(db_path: Path, json_path: Path) -> None:
    conn = sqlite3.connect(db_path)
    cols = set(_cols(conn, "saved_ads"))
    status_expr = "COALESCE(status, 'active')" if "status" in cols else "'active'"
    rows = conn.execute(
        "SELECT id, title, url, saved_price, saved_date, "
        f"{status_expr} FROM saved_ads ORDER BY id"
    ).fetchall()
    conn.close()
    ads = [
        {
            "id": r[0],
            "title": r[1],
            "url": r[2],
            "saved_price": r[3],
            "saved_date": r[4],
            "status": r[5] or "active",
        }
        for r in rows
    ]
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(ads, f, ensure_ascii=False, indent=2)


def _git_stage(path: str, stage: int) -> bytes | None:
    proc = subprocess.run(
        ["git", "show", f":{stage}:{path}"],
        cwd=ROOT,
        capture_output=True,
    )
    if proc.returncode != 0 or not proc.stdout:
        return None
    return proc.stdout


def _unmerged(path: str) -> bool:
    proc = subprocess.run(
        ["git", "ls-files", "-u", "--", path],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    return bool(proc.stdout.strip())


def main() -> int:
    db_path = ROOT / DB_NAME
    if _unmerged(DB_NAME):
        left = _git_stage(DB_NAME, 2)
        right = _git_stage(DB_NAME, 3)
        tmp_dir = Path("/tmp")
        sides = []
        for label, blob in (("ours", left), ("theirs", right)):
            if not blob:
                continue
            side = tmp_dir / f"njuskalo-merge-{label}.db"
            side.write_bytes(blob)
            sides.append(side)
        if len(sides) == 1:
            shutil.copy(sides[0], db_path)
        elif len(sides) == 2:
            merge_databases(sides[0], sides[1], db_path)
        else:
            print("merge_state: nema git stageova za njuskalo.db", file=sys.stderr)
            return 1
        print(f"merge_state: spojen njuskalo.db iz {len(sides)} strane")
    elif not db_path.exists():
        print("merge_state: nema njuskalo.db", file=sys.stderr)
        return 1
    export_saved_json(db_path, ROOT / JSON_NAME)
    print("merge_state: saved_ads.json obnovljen iz baze")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
