---
name: reuse-task-procedures
description: >-
  Use before doing any task that could come up again: running or building a
  project, updating Docker, deploying, fixing a recurring error, setting up a
  tool, following a team convention. Search INDEX.md first and follow the saved
  guide. If none exists and the task is worth repeating, do the task, then save
  how it was done as a short guide, plus a short script when the task can be
  automated, so any agent (even a small model) can repeat it next time.
author: "Armin Dashti"
uuid: a71bef8a-455b-44b1-b914-d9bc793e6c4c
---

# Reuse task procedures

Save how a task was done, so the next time it is asked for, any agent can
follow a short proven guide instead of working it out from scratch. Some tasks
are saved as step-by-step instructions only. Tasks that can be automated also
get a small script.

## Layout

Everything lives in this skill's own folder (the folder containing this
`SKILL.md`), wherever it is on the machine. Never assume a fixed path.

```
SKILL.md
INDEX.md      one row per saved task: name, type, what it does, keywords
guides/       one short <task-name>.md per saved task (always)
scripts/      <task-name>.<ext> for tasks of type "script" (only those)
```

**How to find and use a saved task:** search `INDEX.md`, read only the
matching guide in `guides/`, then follow it. Do not list or open files in
`scripts/` or `guides/` to browse. Open a script only to fix or extend it.

## Step 1: Search the index

```bash
rg -i "docker|rebuild" INDEX.md
```
```powershell
Select-String -Path INDEX.md -Pattern "docker|rebuild"
```

Try two or three keywords: the action (`run`, `rebuild`, `deploy`, `fix`), the
tool (`docker`, `git`, `npm`), and the kind of project or error. If a row
fits, read its guide and go to Step 4.

## Step 2: Decide whether to save it, and how

Save a task when any of these is true:

- The user says "again", "every time", "whenever", "after each change", or has
  asked for the same thing before.
- It is a routine chore: run, build, restart, deploy, back up, sync repos,
  clean caches, health checks.
- It took real effort to figure out (a tricky fix, a setup with gotchas, a
  convention to follow) and the knowledge would save time next time.

Do not save one-off questions, trivial single commands, or creative work that
will be different every time.

Then pick the type:

- **script:** the steps are the same commands every time, with only a few
  values changing (path, name, port). Save a guide and a script.
- **steps:** the task needs judgment, reading code, GUI clicks, or choices that
  depend on the situation, but follows a known procedure. Save a guide only.

## Step 3: Do the task, the way you will save it

The first time is both the real task and the test of the procedure.

- **script:** write the script and do the job by running it, not by hand. If it
  fails, fix the script and run it again until the task is done.
- **steps:** do the task while noting each step that actually worked, the exact
  commands, and any trap you hit.

Save the guide (and script) only after the task succeeded, so everything saved
is known to work. Record what really worked, not what should work in theory.

### Script rules

- **Short and useful:** only the code the task needs, one task per script.
- **Works on any machine:** no hardcoded user paths, usernames, hosts or ports.
  Take them as parameters with defaults that work anywhere, such as the current
  directory.
- **Language:** PowerShell (`.ps1`) for Windows, Bash (`.sh`) for Linux and
  macOS, Python (`.py`) when it must run everywhere or needs real logic.
- **No secrets:** read passwords, tokens and keys from environment variables or
  the existing credential store, never from the script.
- **Safe by default:** stop on the first error (`$ErrorActionPreference='Stop'`,
  `set -euo pipefail`). No `docker compose down -v`, no `docker volume rm`, no
  deleting user data, no force-push.
- **Clear result:** print one short line at the end saying what happened.

## Step 4: Follow a saved guide

Do what the guide says. If something fails or the guide is out of date, fix the
guide (and script) after you finish, so the next agent gets the working
version.

## Step 5: Write the guide

Name it `guides/<task-name>.md`. The task name is lowercase kebab-case,
`verb-target`, for example `rebuild-compose-stack` or `fix-telegram-proxy`. A
script for that task uses the same name, for example
`scripts/rebuild-compose-stack.sh`.

Keep guides short enough for a small model to follow in one read: plain words,
numbered steps, exact commands, no background essays.

Script guide:

```markdown
# rebuild-compose-stack (script)

Rebuilds and restarts a Docker Compose app without deleting its data.

**Run:** `bash scripts/rebuild-compose-stack.sh [project-dir]`
- `project-dir`: folder with the compose file. Default: current folder.

**Needs:** Docker with Compose v2.
**Success:** prints `stack rebuilt, N containers up`.
**If it fails:** run `docker compose logs` in the project folder.
```

Steps guide:

```markdown
# add-api-endpoint (steps)

Adds a new REST endpoint following the project's existing pattern.

1. Find an existing endpoint of the same kind and copy its structure.
2. Add the route, handler and request/response types next to it.
3. Register the route where the others are registered.
4. Run the project's tests and build; both must pass.

**Done when:** the endpoint answers and tests pass.
**Watch out:** keep naming and error format identical to the other endpoints.
```

## Step 6: Add the index row

Add one row to `INDEX.md`, keeping rows sorted by name:

```
| rebuild-compose-stack | script | Rebuild and restart a Compose app, keeping data | docker, compose, rebuild, restart |
| add-api-endpoint | steps | Add a REST endpoint in the project's style | api, endpoint, route, backend |
```

Update the row whenever the guide changes meaning. If you delete a saved task,
delete its guide, script and row together.

## Step 7: Report

Tell the user whether you reused or saved a procedure, its name and type, and
for scripts the one-line command to run it themselves.

## Never

- Browse `guides/` or `scripts/`; search `INDEX.md` first.
- Save a guide or script that has not successfully done the task.
- Save a script without its guide and index row, or a guide without its row.
- Hardcode paths, users or hosts, or write secrets into a guide or script.
- Save destructive or one-time operations.
