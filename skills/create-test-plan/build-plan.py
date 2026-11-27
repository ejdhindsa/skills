#!/usr/bin/env python3
"""Builds the test plan page from a plan JSON file.

usage: build-plan.py <plan.json> <plan.html> [--theme <theme.css>]

Theme: --theme, else $CREATE_TEST_PLAN_HOME/theme.css (default home ~/.claude/create-test-plan),
else theme-blackfox.css next to this script. A theme defines the CSS tokens on :root that
theme-blackfox.css defines; it may start with an @import of Google Fonts.

plan.json schema (fields ending in Html are HTML; everything else is plain text):
{
  "meta": {
    "id": "proj-123",                       # keys the viewer's saved results; keep it on updates
    "title": "Order Export Test Plan",      # <title>: a 2-4 word name
    "summaryHtml": "...",                   # what the plan proves and where it runs, one paragraph
    "ticket": {"key": "PROJ-123", "summary": "...", "url": "https://..."},   # optional; key null for a pasted ticket
    "repos": [{"name": "orders-api", "branch": "...", "base": "develop",
               "mergeBase": "6c1a2b3", "head": "63a5c79", "uncommitted": false}],
    "env": "...",                           # services, databases and ports the plan uses; goes into the prompts
    "agentNotes": "...",                    # optional: how an agent runs REPL or other interactive steps headless
    "terminals": [{"id": "T1", "what": "API node REPL"}],
    "time": "about 40 minutes",
    "dryRun": {"date": "2026-11-27", "commit": "63a5c79", "scope": "full|partial", "outcome": "..."},  # or null
    "updated": "2026-11-27",
    "url": "https://claude.ai/..."          # set after the first publish
  },
  "checkFirst": [{"kind": "gap|warn", "html": "..."}],
  "notes": [{"title": "Two nodes.", "html": "...", "kind": "bad"}],          # kind optional
  "fields": [{"id": "sidA", "label": "Event sid A", "default": "+30d", "hint": "...", "from": "A1"}],
  "coverage": [{"item": "ticket scope item", "steps": ["a1"], "status": "covered|partial|untested", "note": "..."}],
  "parts": [{"id": "a", "kind": "auto|setup|test|regression|cleanup", "title": "A. Export an order",
             "needsHtml": "...", "resetNotNeeded": "reason"}],
  "steps": [{"id": "a1", "part": "a", "num": "A1", "title": "...", "why": "...",
             "cmds": [{"term": "T1 REPL", "text": "..."}], "do": ["..."], "expect": ["..."],
             "covers": [{"repo": "orders-api", "file": "src/orders/export.js", "symbol": "exportOrder"}],
             "causes": ["..."], "reset": true}],
  "troubleshooting": [{"seeHtml": "...", "causeHtml": "...", "fixHtml": "..."}],
  "dryRunFindings": [{"whatHtml": "...", "whereHtml": "...", "impactHtml": "..."}]
}

{{fieldId}} in why, cmds, do and expect is replaced with the viewer's value for that field.
A field default of "+30d" or "-2d" means that many days from the day the page is opened.
"""
import hashlib, html, json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
PART_KINDS = {"auto", "setup", "test", "regression", "cleanup"}
STATUSES = {"covered", "partial", "untested"}
PLACEHOLDER = re.compile(r"\{\{(\w+)\}\}")

args = sys.argv[1:]
theme_path = None
if "--theme" in args:
    i = args.index("--theme")
    if i + 1 >= len(args):
        sys.exit("--theme needs a path")
    theme_path = args[i + 1]
    del args[i:i + 2]
if len(args) != 2:
    sys.exit(__doc__.split("\n\n")[1])
src, out = args

with open(src, encoding="utf-8") as fh:
    plan = json.load(fh)

errors, warnings = [], []
err, warn = errors.append, warnings.append

meta = plan.get("meta") or {}
for key in ("id", "title", "summaryHtml", "env"):
    if not meta.get(key):
        err(f"meta.{key} is required")
repos = meta.get("repos") or []
if not repos:
    err("meta.repos needs at least one repo")
for i, r in enumerate(repos):
    for key in ("name", "branch", "base", "mergeBase", "head"):
        if not r.get(key):
            err(f"meta.repos[{i}].{key} is required")

fields = plan.get("fields") or []
field_ids = set()
for i, f in enumerate(fields):
    if not f.get("id") or not f.get("label"):
        err(f"fields[{i}] needs id and label")
    elif f["id"] in field_ids:
        err(f"fields: duplicate id {f['id']}")
    field_ids.add(f.get("id"))

parts = plan.get("parts") or []
part_ids = {}
for i, p in enumerate(parts):
    pid = p.get("id")
    if not pid or not p.get("title"):
        err(f"parts[{i}] needs id and title")
        continue
    if pid in part_ids:
        err(f"parts: duplicate id {pid}")
    if p.get("kind") not in PART_KINDS:
        err(f"part {pid}: kind must be one of {sorted(PART_KINDS)}")
    part_ids[pid] = p
kinds = [p.get("kind") for p in parts]
if kinds.count("auto") != 1:
    err("plan needs exactly one part of kind auto (step 0: automated checks)")
if "test" not in kinds:
    err("plan needs at least one part of kind test")
if "regression" not in kinds:
    err("plan needs a part of kind regression (regression and rollout checks)")
if "cleanup" not in kinds:
    err("plan needs a part of kind cleanup")

def check_text(where, text):
    for name in PLACEHOLDER.findall(text or ""):
        if name not in field_ids:
            err(f"{where}: {{{{{name}}}}} is not a field id")

steps = plan.get("steps") or []
step_ids, step_refs = set(), set()
for i, s in enumerate(steps):
    sid = s.get("id") or f"#{i}"
    if not s.get("id"):
        err(f"steps[{i}] needs an id")
    elif s["id"] in step_ids:
        err(f"steps: duplicate id {s['id']}")
    step_ids.add(sid)
    step_refs.update(x for x in (s.get("id"), s.get("num")) if x)
    if s.get("part") not in part_ids:
        err(f"step {sid}: part {s.get('part')!r} does not exist")
    for key in ("title", "why"):
        if not s.get(key):
            err(f"step {sid}: {key} is required")
    cmds, todo, expect = s.get("cmds") or [], s.get("do") or [], s.get("expect") or []
    if not cmds and not todo:
        err(f"step {sid}: needs cmds or do")
    if not expect or not all(isinstance(x, str) and x.strip() for x in expect):
        err(f"step {sid}: expect needs at least one non-empty line")
    for j, c in enumerate(cmds):
        if not c.get("term") or not c.get("text"):
            err(f"step {sid}: cmds[{j}] needs term and text")
        check_text(f"step {sid} cmds[{j}]", c.get("text"))
    for j, t in enumerate(todo):
        check_text(f"step {sid} do[{j}]", t)
    for j, t in enumerate(expect):
        check_text(f"step {sid} expect[{j}]", t)
    check_text(f"step {sid} why", s.get("why"))
    for j, c in enumerate(s.get("covers") or []):
        if not c.get("file"):
            err(f"step {sid}: covers[{j}] needs file")
    kind = part_ids.get(s.get("part"), {}).get("kind")
    if kind in ("test", "regression") and not s.get("reset") and not s.get("covers"):
        warn(f"step {sid}: no covers, so the fix prompt can't point at the code it exercises")
    s["rev"] = hashlib.sha1(json.dumps([cmds, todo, expect], sort_keys=True).encode()).hexdigest()[:10]

terminal_ids = [t.get("id") for t in meta.get("terminals") or [] if t.get("id")]
for s in steps:
    for c in s.get("cmds") or []:
        term = c.get("term") or ""
        if term and not any(term == t or term.startswith(t + " ") for t in terminal_ids):
            warn(f"step {s.get('id')}: terminal {term!r} is not declared in meta.terminals")

for pid, p in part_ids.items():
    own = [s for s in steps if s.get("part") == pid]
    if not own:
        err(f"part {pid}: has no steps")
    if p.get("kind") in ("test", "regression") and not any(s.get("reset") for s in own) and not p.get("resetNotNeeded"):
        err(f"part {pid}: needs a step with reset: true, or resetNotNeeded with the reason")

for f in fields:
    if f.get("from") and f["from"] not in step_refs:
        warn(f"field {f.get('id')}: from {f['from']!r} matches no step id or num")

for i, c in enumerate(plan.get("coverage") or []):
    if not c.get("item"):
        err(f"coverage[{i}] needs item")
    if c.get("status") not in STATUSES:
        err(f"coverage[{i}]: status must be one of {sorted(STATUSES)}")
    for ref in c.get("steps") or []:
        if ref not in step_ids:
            err(f"coverage[{i}]: step {ref!r} does not exist")
    if c.get("status") == "covered" and not c.get("steps"):
        err(f"coverage[{i}]: covered but lists no steps")

for i, c in enumerate(plan.get("checkFirst") or []):
    if c.get("kind") not in ("gap", "warn") or not c.get("html"):
        err(f"checkFirst[{i}] needs kind gap|warn and html")

if not plan.get("troubleshooting"):
    err("troubleshooting needs at least one row")
for i, t in enumerate(plan.get("troubleshooting") or []):
    for key in ("seeHtml", "causeHtml", "fixHtml"):
        if not t.get(key):
            err(f"troubleshooting[{i}].{key} is required")

for w in warnings:
    print("warning:", w, file=sys.stderr)
if errors:
    for e in errors:
        print("error:", e, file=sys.stderr)
    sys.exit(1)

if not theme_path:
    home = os.environ.get("CREATE_TEST_PLAN_HOME") or os.path.expanduser("~/.claude/create-test-plan")
    user_theme = os.path.join(home, "theme.css")
    theme_path = user_theme if os.path.isfile(user_theme) else os.path.join(HERE, "theme-blackfox.css")
with open(theme_path, encoding="utf-8") as fh:
    theme = fh.read().replace("</", "<\\/")
with open(os.path.join(HERE, "template.html"), encoding="utf-8") as fh:
    page = fh.read()

data = json.dumps(plan, ensure_ascii=False).replace("<", "\\u003c")
for token, value in (("__TITLE__", html.escape(meta["title"])), ("/*__THEME__*/", theme), ("__DATA__", data)):
    if page.count(token) != 1:
        sys.exit(f"template.html must contain {token} exactly once")
    page = page.replace(token, value)

os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
with open(out, "w", encoding="utf-8") as fh:
    fh.write(page)
print(f"wrote {out}: {len(parts)} parts, {len(steps)} steps, {len(warnings)} warnings, theme {theme_path}")
