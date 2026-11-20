#!/usr/bin/env python3
"""Render a ticket's drill history JSON into the report page.

Usage: build-report.py <ticket.json> <out.html>
"""
import json
import pathlib
import sys

REQUIRED_RUN_KEYS = {"date", "repos", "branch", "head", "overall", "explainBack", "questions", "strong", "weak", "notTested"}
CATEGORIES = {"what-why", "system", "edge-tests", "alternatives", "fundamentals", "redrill"}


def validate(data):
    errors = []
    if not data.get("ticket"):
        errors.append("missing 'ticket'")
    runs = data.get("runs") or []
    if not runs:
        errors.append("'runs' is empty")
    for i, run in enumerate(runs):
        missing = REQUIRED_RUN_KEYS - run.keys()
        if missing:
            errors.append(f"run {i}: missing {sorted(missing)}")
            continue
        for q in run["questions"]:
            if q.get("category") not in CATEGORIES:
                errors.append(f"run {i} Q{q.get('n')}: bad category {q.get('category')!r}")
            if not isinstance(q.get("score"), (int, float)) or not 0 <= q["score"] <= 10:
                errors.append(f"run {i} Q{q.get('n')}: score must be 0-10")
    return errors


def main():
    src, out = map(pathlib.Path, sys.argv[1:3])
    data = json.loads(src.read_text())
    errors = validate(data)
    if errors:
        sys.exit("Invalid report data:\n  " + "\n  ".join(errors))
    template = (pathlib.Path(__file__).parent / "report-template.html").read_text()
    payload = json.dumps(data).replace("</", "<\\/")
    title = f"{data['ticket']} drill"
    html = template.replace("__TITLE__", title).replace("__DATA__", payload)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(html)
    print(out)


if __name__ == "__main__":
    main()
