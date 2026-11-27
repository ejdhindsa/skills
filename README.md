# Claude Code skills

| Command | What it does |
|---|---|
| `/create-test-plan` | Builds a local test plan for your branch from its diff and its Jira ticket, and publishes it as a runbook page with pass/fail per step. |
| `/what-did-i-even-do` | End-of-feature comprehension drill for your branch changes. |

## Install

You need Claude Code, `git`, `bash` and `python3` on your `PATH`.

```sh
git clone https://github.com/ejdhindsa/skills.git ~/Git/claude-skills
~/Git/claude-skills/install.sh
```

`install.sh` links each folder under `skills/` into `~/.claude/skills/`. If a command doesn't show
up in a running session, start a new one.

- **Update:** `git -C ~/Git/claude-skills pull`. The links point at the clone, so the next session
  uses the new version.
- **One skill only:** link just that folder:
  `ln -s ~/Git/claude-skills/skills/create-test-plan ~/.claude/skills/create-test-plan`
- **A folder with the same name already exists** in `~/.claude/skills/`: `install.sh` skips it and
  says so. Move that folder away, then run `install.sh` again.
- **Windows:** use WSL, where the steps above work as written. In Git Bash, `ln -s` copies the
  folder instead of linking it unless Developer Mode is on and `MSYS=winsymlinks:nativestrict` is
  set. With a copy, delete `~/.claude/skills/<name>` and run `install.sh` again after each pull.

## /create-test-plan

Run it inside a repo on your feature branch:

```text
/create-test-plan                          # asks for the base branch
/create-test-plan --base develop           # skips that question
/create-test-plan --ticket PROJ-123        # when the branch name has no ticket key
/create-test-plan api web --base develop   # run from a folder of repos: one plan across them
/create-test-plan --full-run               # also run every step once before publishing
/create-test-plan --no-run                 # run nothing, not even the read-only checks
```

What happens:

1. It diffs the branch against the base, asks whether to include uncommitted changes, and reads the
   Jira ticket with its comments, linked issues and epic.
2. On the first run in a repo it works out how your machine runs it (services, ports, start
   commands) and asks you to confirm what it can't verify. It saves this as environment notes.
3. It asks only what the code, ticket and notes can't answer, then writes the plan: step 0
   (lint and specs), setup, independent parts with reset steps, regression and rollout checks, and
   cleanup. A ticket coverage map lists scope items with no change, and changes the ticket doesn't
   mention.
4. It checks the plan by running step 0 (lint and specs) and every step that only reads. It starts
   nothing and writes nothing. With `--full-run` it lists what a full run would write, waits for your
   yes, then runs every step in a separate agent.
5. It publishes the page as a private claude.ai artifact. Share it with reviewers from the page's
   Share menu.

The page records pass, fail or skip and notes for each step, and fills commands with the values
you paste into its side panel. Its buttons copy:

- **Results as Markdown**, for the PR or the ticket.
- **A run prompt**, which hands the plan, or the parts you tick, to an agent that runs every step
  and reports what it saw. Paste it into a Claude Code session started at the repo root.
- **A fix prompt**, which hands the failed steps, your notes and the suspected causes you ticked to
  an agent. The agent reproduces each failure, finds the cause and proposes a fix before editing
  anything.

The agent's report ends with a block of results. Paste the report into **Paste agent results** and
the page records pass, fail or skip and the agent's notes for every step, so the fix prompt works
straight from the agent's run.

Run the command again on the same ticket after new commits and it updates the same plan and page.
Results you recorded on unchanged steps stay in your browser.

### Requirements

- **Jira:** the Atlassian connector in Claude Code. Without it, the command asks you to paste the
  ticket's goal, scope and acceptance criteria.
- **Publishing:** a claude.ai account with artifacts enabled.

### What it writes

Everything goes to `~/.claude/create-test-plan/`. Set `CREATE_TEST_PLAN_HOME` to use another folder.

| Path | Contents |
|---|---|
| `env/<repo>.md` | Your machine's notes for that repo: services, ports, start commands, known errors. Facts you haven't confirmed are marked `(unconfirmed)`. |
| `plans/<ticket>/plan.json` | The plan. `plan.html` next to it is built from it. |
| `plans/<ticket>/scripts/` | Helper scripts a plan needs. |
| `mocks/<service>/` | Throwaway mock servers for external services the repo has no mock for. |
| `theme.css` | Optional. Copy `skills/create-test-plan/theme-blackfox.css` here and change the colors and fonts to restyle every page. |

It writes nothing inside your repos. It never commits, pushes or posts to Jira. Plans and dry runs
use local services only.

### Cost

Measured once: a 9-file change in one repo, the first run in that repo, no dry run. That run took
32 model calls and about 6 minutes, and cost about $1.20 at Claude Sonnet 5.5 API rates. Bigger
diffs and more repos cost more. `--full-run` is the most expensive option: on a larger plan, a full
run took 82 model calls on its own.
