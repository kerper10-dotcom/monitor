#!/usr/bin/env python3
"""Pokreni jedan workflow_dispatch i pričekaj kraj.

Izlaz 0 = gotovo i u logu nema CAPTCHA-e.
Izlaz 10 = gotovo, ali CAPTCHA (pacer mora stati).
Izlaz 1 = run nije uspio ili nije završio.
"""

import json
import re
import subprocess
import sys
import time


def gh_json(args: list[str]):
    out = subprocess.check_output(["gh", *args], text=True)
    return json.loads(out)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: pace_once.py <workflow.yml>", file=sys.stderr)
        return 1
    wf = sys.argv[1]
    before = {
        r["databaseId"]
        for r in gh_json(
            [
                "run", "list", "--workflow", wf, "--limit", "8",
                "--json", "databaseId,status,conclusion",
            ]
        )
    }
    subprocess.check_call(["gh", "workflow", "run", wf, "--ref", "main"])
    deadline = time.time() + 18 * 60
    seen = None
    while time.time() < deadline:
        time.sleep(15)
        rows = gh_json(
            [
                "run", "list", "--workflow", wf, "--limit", "8",
                "--json", "databaseId,status,conclusion",
            ]
        )
        fresh = [r for r in rows if r["databaseId"] not in before]
        if not fresh:
            continue
        seen = fresh[0]
        if seen["status"] == "completed":
            break
    else:
        print("timeout", file=sys.stderr)
        return 1

    run_id = seen["databaseId"]
    if seen["conclusion"] != "success":
        print(f"{run_id} failed {seen['conclusion']}")
        return 1

    log = subprocess.check_output(
        ["gh", "run", "view", str(run_id), "--log"],
        text=True,
        errors="replace",
    )
    caps = [int(n) for n in re.findall(r"(\d+) CAPTCHA", log)]
    oks = [int(n) for n in re.findall(r"(\d+) OK,", log)]
    captcha = caps[-1] if caps else log.count("CAPTCHA na str")
    ok = oks[-1] if oks else 0
    print(f"{run_id} ok={ok} captcha={captcha}")
    return 10 if captcha else 0


if __name__ == "__main__":
    raise SystemExit(main())
