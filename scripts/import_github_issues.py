#!/usr/bin/env python3
"""
Import GitHub issues from CSV using gh CLI.

CSV columns expected:
- Title
- Body
- Labels (comma-separated)
- Milestone
- Priority
- Estimate
- Area
- Dependencies

Usage:
  python3 scripts/import_github_issues.py \
    --repo <owner/repo> \
    --csv github-issues-import-template.csv \
    [--dry-run]

Notes:
- Requires gh auth: `gh auth status`
- Milestones must already exist in the target repo (exact name match).
- If `Milestone` does not exist, issue is created without milestone and a warning is printed.
"""

from __future__ import annotations

import argparse
import csv
import json
import shlex
import subprocess
import sys
from pathlib import Path


def run(cmd: list[str], check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, text=True, capture_output=True, check=check)


def get_existing_milestones(repo: str) -> set[str]:
    cmd = [
        "gh",
        "api",
        f"repos/{repo}/milestones?state=all&per_page=100",
        "--jq",
        ".[].title",
    ]
    proc = run(cmd, check=False)
    if proc.returncode != 0:
        print("WARN: Could not fetch milestones. Continuing without milestone validation.", file=sys.stderr)
        return set()
    return {line.strip() for line in proc.stdout.splitlines() if line.strip()}


def build_labels(row: dict[str, str]) -> list[str]:
    labels = []
    base = (row.get("Labels") or "").strip()
    if base:
        labels.extend([x.strip() for x in base.split(",") if x.strip()])

    priority = (row.get("Priority") or "").strip()
    if priority:
        labels.append(f"priority:{priority}")

    area = (row.get("Area") or "").strip()
    if area:
        labels.append(f"area:{area}")

    # de-dup while preserving order
    seen = set()
    out = []
    for l in labels:
        if l not in seen:
            seen.add(l)
            out.append(l)
    return out


def build_body(row: dict[str, str]) -> str:
    body = (row.get("Body") or "").strip()
    estimate = (row.get("Estimate") or "").strip()
    deps = (row.get("Dependencies") or "").strip()

    meta = []
    if estimate:
        meta.append(f"- Estimate: `{estimate}`")
    if deps:
        meta.append(f"- Dependencies: {deps}")

    if meta:
        body = body + "\n\n---\n" + "\n".join(meta)

    return body


def ensure_label_exists(repo: str, label: str) -> None:
    # idempotent: create if missing
    check_cmd = ["gh", "label", "list", "--repo", repo, "--search", label, "--json", "name"]
    p = run(check_cmd, check=False)
    if p.returncode != 0:
        return
    try:
        current = {x["name"] for x in json.loads(p.stdout or "[]")}
    except Exception:
        current = set()
    if label in current:
        return

    create_cmd = ["gh", "label", "create", label, "--repo", repo, "--force"]
    run(create_cmd, check=False)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True, help="GitHub repo in owner/name format")
    parser.add_argument("--csv", required=True, help="Path to CSV file")
    parser.add_argument("--dry-run", action="store_true", help="Print commands without executing")
    args = parser.parse_args()

    csv_path = Path(args.csv)
    if not csv_path.exists():
        print(f"ERROR: CSV not found: {csv_path}", file=sys.stderr)
        return 1

    # Validate gh auth early
    auth = run(["gh", "auth", "status"], check=False)
    if auth.returncode != 0 and not args.dry_run:
        print("ERROR: gh is not authenticated. Run: gh auth login", file=sys.stderr)
        return 1

    milestones = get_existing_milestones(args.repo)

    created = 0
    skipped = 0

    with csv_path.open("r", encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f)
        for i, row in enumerate(reader, start=2):
            title = (row.get("Title") or "").strip()
            if not title:
                print(f"WARN: line {i}: missing Title, skipping", file=sys.stderr)
                skipped += 1
                continue

            body = build_body(row)
            labels = build_labels(row)
            milestone = (row.get("Milestone") or "").strip()

            cmd = ["gh", "issue", "create", "--repo", args.repo, "--title", title, "--body", body]

            for label in labels:
                ensure_label_exists(args.repo, label)
                cmd.extend(["--label", label])

            if milestone:
                if milestones and milestone in milestones:
                    cmd.extend(["--milestone", milestone])
                elif milestones:
                    print(f"WARN: line {i}: milestone '{milestone}' not found; creating issue without milestone", file=sys.stderr)

            if args.dry_run:
                print("DRY_RUN:", " ".join(shlex.quote(c) for c in cmd))
            else:
                proc = run(cmd, check=False)
                if proc.returncode == 0:
                    created += 1
                    print(proc.stdout.strip())
                else:
                    skipped += 1
                    print(f"ERROR: line {i}: failed to create '{title}'", file=sys.stderr)
                    print(proc.stderr.strip(), file=sys.stderr)

    print(f"\nDone. created={created} skipped={skipped}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
