---
name: create-test-plan
description: Builds a local test plan for a branch's changes. Reads the diff against a base branch you name, the Jira ticket (with its comments, linked issues and epic) and earlier test plans, and asks only what the code can't answer. Publishes an interactive runbook page with commands, expected output, pass/fail and notes per step, and a values panel. The page also builds paste-ready prompts that have an agent run the plan or diagnose failed steps. Works on one repo, or on several git repos in direct subdirectories. Only run when the user types /create-test-plan.
argument-hint: [repo-name...] [--base <branch>] [--ticket <KEY>]
disable-model-invocation: true
---

# /create-test-plan

Produce a test plan that a developer, or an agent, can follow on their own machine to prove the
branch does what its ticket asks and breaks nothing next to it. The plan is a JSON file built into
an HTML page from a fixed template. You write the JSON; the scripts do the rest.

Shell variables do not persist between Bash calls, so start every Bash call that uses these paths
with `SKILL=~/.claude/skills/create-test-plan; DATA="${CREATE_TEST_PLAN_HOME:-$HOME/.claude/create-test-plan}"`.
`$DATA` is the user's own folder: environment notes, plans, throwaway mocks and scripts, and an
optional `theme.css`. Create it on first use (`mkdir -p "$DATA/env" "$DATA/plans" "$DATA/mocks"`).

## Hard rules

- **Local only.** Plans and dry runs touch this machine's services only. Before any dry run, check
  that every database, Redis and HTTP target the steps use resolves to localhost, 127.0.0.1 or a
  local container. If one does not, stop and tell the user.
- **The repo's own "never run" lists apply** (AGENTS.md, CLAUDE.md, CONTRIBUTING.md). A plan never
  contains those commands, deploys, pushes images or touches shared environments.
- **Never post to Jira** or any other shared tool. Read only.
- **Never commit, push, stash, reset or check out** in the user's repos. Never edit repo files or
  env files: start commands override variables on the command line instead.
- **No secrets.** Never copy passwords, tokens, keys or private links from env files or databases
  into env notes, plans or chat. Commands that read sensitive output filter it to the fields the
  step needs.
- **Plain prose.** Write plan text in plain technical English whatever output style or persona the
  session uses. The page goes to PR reviewers.

## Phase 1: scope and base

1. **Repos.** If `.` is a git repo, scope is that repo. Otherwise every direct subdirectory that is
   a git repo; repo names in `$ARGUMENTS` filter the set (a named repo that isn't a git repo here is
   an error). No repos: say so and stop. More than one repo means one feature across repos: the
   plan gets steps at the contracts between them (Moleculer actions and events, REST routes,
   socket events, shared DTOs, migrations another repo reads).
2. **Base branch and uncommitted changes, one round.** Run `$SKILL/prep.sh <repo> --candidates`
   for each repo (one Bash call, chained). Then ask in one AskUserQuestion call:
   - **Base**, one question per repo, unless `--base` was given: each existing candidate as an
     option with its `ahead` and `behind` counts in the description, nearest first (fewest
     commits ahead) and marked "(Recommended)". The user can type another branch under Other. Say so in the question when
     `origin/HEAD` differs from the nearest candidate.
   - **Uncommitted**, one question, only when a repo prints `uncommitted:` lines: "Committed
     changes only" or "Include uncommitted changes". Name up to 10 files and flag env files.
   With more than three repos, split the base questions over extra rounds.
3. **Digest.** Run `$SKILL/prep.sh <repo> --base <branch> --out <scratchpad>/ctp [--ticket <KEY>]`
   per repo, chained in one Bash call. Read each digest. A non-zero exit explains why on stderr:
   report it for that repo and stop for that repo; do not route around it with manual git.
4. **Uncommitted, applied.** If included, plan from the worktree diff and untracked files, and set
   `uncommitted: true` on that repo. If not, add a `checkFirst` warning naming the files that run
   locally but are not in the branch.
5. Nothing committed and nothing included: say so and stop.

## Phase 2: the ticket

Take the key from `--ticket`, else from the digest. Repos with different keys: ask which applies.

1. Load Atlassian tools with ToolSearch (`+atlassian jira issue`). The MCP counts as configured
   only when an issue-read tool such as `getJiraIssue` loads; `authenticate` tools alone do not
   count.
2. **Configured and a key exists:** pass the site hostname (e.g. `example.atlassian.net`) as
   `cloudId` when you know it from a ticket link or the env notes. Otherwise call
   `getAccessibleAtlassianResources` once (ask if there are several sites). Then read:
   - the issue with `fields: ["summary", "description", "issuelinks", "parent", "status"]` and
     `fieldsByKeys: true`: goal, scope, acceptance criteria, epic and links. The default views
     add avatars, icons and custom fields worth thousands of tokens and nothing to the plan.
   - its comments (`listJiraIssueComments`): later decisions override the description
   - linked issues and the epic: summaries from the issue response. Read a linked issue's
     description only to draw a boundary, e.g. "PROJ-124 owns the sync service, so this plan
     doesn't test it".
3. **Not configured, the call fails, or no key:** ask the user to paste the ticket: goal, scope and
   acceptance criteria, plus any decisions made since. Wait for it. Never build a plan from the
   code alone.

## Phase 3: environment notes

Read `$DATA/env/<repo>.md` for every repo in scope. These are the user's machine facts: services,
ports, start commands, how to read each database and queue, mocks, how an agent runs interactive
steps, and known errors with fixes.

**Missing: discover, confirm, save.**
1. Read the setup parts of README, CONTRIBUTING and AGENTS.md, the compose files, `package.json`
   scripts, `.nvmrc`, env file keys (hosts, ports, database names and feature flags only, never
   secret values), mock servers and REPL tooling.
2. Check what is running: `docker ps --format '{{.Names}} {{.Ports}}'`, and which ports listen.
3. Draft the notes. Then ask the user, in one or two AskUserQuestion rounds, about what you could
   not verify: which database each node uses, which containers they normally run, whether a second
   node (e.g. an API node and a worker node) is part of their setup, and how they run the REPL.
4. Write `$DATA/env/<repo>.md` with these sections: Services and ports; Start commands; Reading
   data (DB, Redis, queues); Mocks; Running headless (for agents); Known errors (you see, cause,
   fix); History (the date each fact was discovered, and the date the user confirmed it). Mark
   every fact the user has not confirmed `(unconfirmed)`, and say which ones in your reply.

**Present:** use it as written. Facts marked `(unconfirmed)` that this plan relies on go into the
Phase 5 questions; on a yes, drop the mark and date the confirmation. A dry run that contradicts
the notes gets a proposed correction in Phase 8.

## Phase 4: understand the change

1. Read the commit log, then the whole diff: in pieces when it is large (`grep -n '^diff --git'`
   for offsets, then Read with offset and limit). Open the full current file for every logic
   change; a hunk alone hides the conditions that decide behaviour.
2. For each behaviour the change adds or alters, record: the entry point a person can trigger (REPL
   action, API route, cron job, event, UI screen), the state it needs, what it writes, and what it
   logs. Copy log messages and error texts from the source. Never invent log lines.
3. **Regression.** For every changed function, action, event, helper or model that has callers
   outside the diff, grep for those callers. Pick the ones most likely to break and plan a check
   for each.
4. **Rollout.** Check what happens while old and new code run side by side: action and event
   params, DTO versions, settings defaults, migration order, feature flags, cached data.
5. **Coverage map.** Map each ticket scope item and acceptance criterion to the behaviours from
   step 2. Record mismatches both ways: a scope item with no matching change, and a change the
   ticket doesn't mention. Both go into `checkFirst` as `gap` items and into your final reply.
6. **Earlier plans.** From the digest's "Earlier test plans", open the ones for the same repos and
   area. Reuse setup steps, data recipes, mocks and troubleshooting rows that apply. Never copy a
   step without checking it against the current code. An older-format plan is an HTML file with
   its steps in a script: `grep -n` it for the changed files, services, tables and actions, and
   read only the matching steps and its troubleshooting table.

## Phase 5: targeted questions

Ask only what the code, ticket, env notes and earlier plans cannot answer: one to three
AskUserQuestion rounds of at most four questions. Each question names what you found that makes it
necessary; put the recommended option first. Typical questions: how to create a state that no
real path reaches, whether an optional path is in scope, an environment fact the notes lack.

Apply these defaults without asking:
- **Audience:** the developer who made the change and their PR reviewers. They know the stack but
  not this branch. Explain why each step exists; don't explain the tools.
- **Test data:** real code paths first (REPL actions, API calls, UI, existing mocks), so the data
  passes through app logic. Direct SQL only for states the app cannot reach: old timestamps, broken
  rows, another location. Every test row carries a unique marker (e.g. `ctp-proj-123-a`) so reset
  steps delete exactly those rows.
- **Nothing reachable calls the change yet** (a helper whose first caller ships in a later
  ticket): write a small script that calls the changed code directly with the repo's own config.
  It refuses to run when the database or service host is not local. Scripts go in
  `$DATA/plans/<plan key>/scripts/`, never in the repo.
- **External service without a mock in the repo:** write a small throwaway mock server in
  `$DATA/mocks/<service>/` and point the node at it with an env override on the start command.
- **Front-end changes:** start the dev server against a local backend, then numbered `do` steps
  naming the exact screen, control and input, and `expect` lines with the exact text or state.
- **Env flags:** override on the command line, never by editing env files.

## Phase 6: write the plan JSON

Path: `$DATA/plans/<plan key>/plan.json` (the plan key is in the digest: the ticket key, else the
branch). The schema is in the docstring of `$SKILL/build-plan.py`; read it before writing.

**Rerun on the same key.** The digest lists the existing plan. Load it and diff from its recorded
head to the new HEAD for each repo. Keep the id of every step whose check is unchanged. Edit steps
whose behaviour changed; the build gives them a new revision, which clears old results on the page.
Add new steps with new ids, remove steps for removed behaviour, and never reuse an id for a
different check. Keep `meta.id` and `meta.url`. Update the heads and `meta.updated`. Ask questions
only about new unknowns.

**Parts, in this order:**
1. `auto`, "Step 0: automated checks": lint, and the specs for the changed files, using the repo's
   own scripts (`npm run lint`, `npx jest <paths>`). Exact commands, expected pass counts.
2. `setup`: install, migrations, mocks, nodes. Each start command is complete and copy-pasteable.
3. `test` parts A, B, C: one area each. `needsHtml` states what the part needs (setup steps, data,
   another part's state). Parts don't depend on each other beyond setup. The last step of each part
   has `reset: true` and returns the data to the state the part started from: delete the marked
   rows, reset watermarks, remove queued jobs. A part that writes nothing (specs, reads, version
   comparisons) sets `resetNotNeeded` to that reason instead.
4. `regression`, "Regression and rollout": the callers from Phase 4 step 3 and the mixed-version
   checks from step 4, with its own reset.
5. `cleanup`: stop processes, remove containers or rows the plan added, and say what stays behind.

**Steps:**
- One behaviour per step. `why` says in one or two sentences what the step proves.
- `cmds` are exact, labelled by terminal (`T1`, `T3 REPL`, `MySQL 3307`, `Browser`). Declare every
  terminal in `meta.terminals`. Use `{{fieldId}}` for values the user captures at run time, and
  declare each in `fields` with `from` (the step that produces it). Use a `default` such as `+30d`
  for dates.
- `expect` lines are observable and exact: log lines copied from the source, values, row counts,
  HTTP status, the text on screen. "Works", "no errors" and "as expected" are not expectations.
  Add what must not happen: no duplicate row, no log line, no second email.
- `covers`: the file and symbol each test step exercises (repo-relative). The fix prompt uses it.
- `causes`: one to four suspected causes when the step fails, each tied to the code: the condition,
  call or config that decides the outcome.
- Commands that print data filter to the fields the step checks. Never print secrets.

**Also fill:** `meta` (summary, ticket, repos with branch, base, merge-base and head, `env` as one
plain line naming services and ports, `agentNotes` from the env notes' headless section, time
estimate); `notes` for "Read this first" (two nodes, timing windows, anything that makes a step
fail if ignored); `coverage`; `checkFirst`; `troubleshooting` from the env notes' known errors that
apply plus the failure modes you expect from this change.

**Prose.** Lead with the point. Specific facts over adjectives: "returns 404", not "fails". Active
voice and imperatives: "Run", "Check". Short sentences: 20 words or fewer per instruction. One name
per thing: name each node, database and terminal once in the notes and reuse that name. Commands,
identifiers, paths and error texts stay byte-for-byte exact. Warnings about data loss get full
sentences. Cut any sentence that could move unchanged into another plan.

## Phase 7: build

Run `python3 $SKILL/build-plan.py $DATA/plans/<key>/plan.json $DATA/plans/<key>/plan.html`. It
validates references, placeholders and the required parts, then prints errors. Fix the JSON and
rebuild until it passes. Fix every warning it prints too: a test step without `covers` weakens
the fix prompt, and an undeclared terminal confuses the agent that runs the plan.
Never hand-edit the HTML.

## Phase 8: dry run

Ask with AskUserQuestion. Each option lists exactly what it writes, by name: databases and ports,
tables, Redis keys and queues, processes it starts, files under `$DATA`.
- **None:** publish from the code alone. Add a "Read this first" note saying that the commands
  and expected values come from reading the code and have never run, so the first run may find
  wrong expectations rather than bugs.
- **Partial:** step 0, plus every check that reads without writing (SELECTs, Redis reads, GET
  requests, config checks). No nodes started unless a read needs one.
- **Full:** start the mocks and nodes in the background (Bash `run_in_background`), run every part
  in order with the env notes' headless method for REPL steps, run every reset, then stop
  everything the dry run started.

While running:
- A step whose command or expectation is wrong: fix the step in the JSON.
- Code that is wrong: never fix it. Record it in `dryRunFindings` (what, where, impact) and tell
  the user in the final reply.
- An environment surprise (a crash on start, a slow timeout, a stuck job): add a `troubleshooting`
  row.
- Set `meta.dryRun` (date, commit, scope, outcome in one line, e.g. "every step matched" or
  "2 steps fail: B3, C1").

Afterwards, propose additions to `$DATA/env/<repo>.md`: new known errors, commands that worked,
corrected ports. Show them and write them only after the user approves. Rebuild the page.

## Phase 9: publish and reply

- **First publish:** publish `plan.html` with the Artifact tool (`icon: "checklist"`, a
  one-sentence `description`). Write the returned URL into `meta.url` and rebuild, so the next run
  updates the same page. If the publish refuses a path outside the working directory, copy
  `plan.html` into the scratchpad and publish that copy. `$DATA` stays the source of truth.
- **Update:** with `meta.url` set, publish to that `url`. Read it first (`action: "read"`) when it
  was not published in this session.

Reply with:
- the link
- the coverage gaps from `checkFirst`
- the dry-run result, and code problems it found
- what the plan does not cover, and why

Say that the page is private until they share it with reviewers. Say that "Copy run prompt" hands
the plan to an agent, and that "Copy fix prompt" turns failed steps, their notes and the ticked
causes into a diagnosis prompt.
