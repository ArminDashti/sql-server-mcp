---
name: redeploy-and-open-pr
description: >-
author: "Armin Dashti"
uuid: 103e2b4b-ebe2-4d05-ac38-d92fada952ca
---

# Redeploy and open a PR

Run after every code change. Order: detect -> rebuild or reinstall -> verify -> PR -> report.

## 1. Detect Docker
- Look in repo root and deploy folders (`deploy/`, `docker/`, `infra/`, `ops/`) for `compose.yaml`, `compose.yml`, `docker-compose.yml`, `docker-compose.*.yml`, `Dockerfile`.
- Found -> step 2. None found -> step 2b (non-Docker).

## 2. Rebuild + re-run (keep data)
1. Find the project already in use; reuse its name and compose files exactly:
   - `docker compose ls`
   - `docker ps --filter label=com.docker.compose.project=<name> --format "{{.Names}}\t{{.Status}}\t{{.Ports}}"`
   - `docker inspect <container> --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}'`
   - Not running yet -> use the default project name (folder name) and default compose file(s).
2. Pre-check data:
   - `docker compose -p <name> -f <files> config` -> review `volumes:` and bind mounts.
   - For DB services: `docker volume ls --filter label=com.docker.compose.project=<name>` and `docker inspect <db-container> --format '{{json .Mounts}}'`; confirm the volume exists and is mounted.
   - If the change would alter a volume name, mount path, or project name -> STOP and ask the user.
3. Build: `docker compose -p <name> -f <files> build`
   - Add `--no-cache` only if Dockerfile/dependencies changed or the change isn't picked up.
4. Recreate: `docker compose -p <name> -f <files> up -d --force-recreate --remove-orphans`
   - Optionally limit to changed services: `... up -d --force-recreate <svc>`.
5. Verify:
   - `docker compose -p <name> -f <files> ps` -> all Up / healthy.
   - Hit health or root URL (`curl -fsS http://localhost:<port>/health` or `Invoke-WebRequest -UseBasicParsing http://localhost:<port>/`).
   - Failure -> `docker compose -p <name> -f <files> logs --tail 100 <svc>`, fix, rebuild, re-verify before continuing.
   - Record URLs/ports for the report.

## 2b. Non-Docker: close, reinstall, run
1. Find how the app is built, installed and started: project scripts (`install*`, `build*`, `run*`, `deploy*` .ps1/.sh/.bat), `package.json` scripts, `Makefile`, `*.csproj`/`*.sln`, installer configs (`*.iss`, `*.wxs`, electron-builder), and the README. Prefer the project's own scripts.
   - Pure library, CLI used in place, or nothing installable/runnable -> just build and run tests, note it in the report, go to step 3.
2. Find every running instance on this machine:
   - Windows: `Get-Process | ? { $_.Path -like "<install-dir>*" -or $_.Path -like "<repo-dir>*" -or $_.ProcessName -eq "<exe-name>" }`; services: `Get-Service | ? { $_.Name -like "*<app>*" }`; scheduled tasks or tray helpers of the app.
   - Linux/macOS: `pgrep -af <name>`; `systemctl list-units | grep <app>`; `launchctl list | grep <app>`.
   - Dev servers started from the repo (node, dotnet, python, electron) count too.
3. Close all of them: ask nicely first (`Stop-Process` without -Force / `CloseMainWindow()`, `kill -TERM`, `Stop-Service`, `systemctl stop`), wait up to ~10 s, then force-kill what is left. Re-check that nothing of the app is still running (locked files break the install).
4. Build: the project's build/publish/package command (e.g. `dotnet publish -c Release`, `npm run build`, `npm run dist`, `cargo build --release`, `go build`).
5. Install again:
   - Has an installer -> run it silently over the existing install (e.g. Inno `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART`, MSI `msiexec /i <msi> /qn`, NSIS `/S`).
   - Otherwise -> copy the build output over the same install location the app already uses (find it from the old process path or shortcut), or use the project's install script.
   - Never delete or reset user data, settings or databases (`%APPDATA%`, `%LOCALAPPDATA%`, `~/.config`, `~/.local/share`, app data folders); only replace program files.
   - Re-register and start any service the app had (`Start-Service`, `systemctl start`).
6. Run: start the installed app the way users do (shortcut target, service, or the project's run script), detached so it keeps running.
7. Verify: the process is running from the new install path, the version/build time is the new one, and its health URL or main window responds. Failure -> read its log, fix, repeat 3-7 before continuing.
## 3. Pull Request
1. Preconditions: `git remote get-url origin` is GitHub and `gh auth status` succeeds. Otherwise report clearly and STOP (no auth workarounds).
2. Branch: if on default branch (`gh repo view --json defaultBranchRef -q .defaultBranchRef.name`), `git switch -c feat/<short-desc>` (or `fix/<short-desc>`).
3. Stage only relevant files: `git add <paths>`; check `git status` / `git diff --cached --stat`. Exclude `.env*`, secrets, credentials, keys, build artifacts, large binaries.
4. Commit (conventional commits): `git commit -m "feat(scope): short summary"`.
5. Push: `git push -u origin HEAD`.
6. PR: `gh pr create --base <default> --title "<title>" --body "<body>"`
   - Body: Summary of change, How verified, Docker rebuild result (services, status, URLs) or non-Docker reinstall result (what was closed, installed, running).
7. Capture the PR URL.

## 4. Final report
- What changed (files, behavior).
- Rebuild result: Docker services + status, URLs/ports; or non-Docker: instances closed, install method, running process/version.
- PR link (or the exact reason it wasn't created).

## Never
- `docker compose down -v`, `docker volume rm`, `docker volume prune`, `docker system prune --volumes`.
- Delete or move bind-mount data dirs; change volume names/paths; rename the compose project (new name = new empty volumes = apparent data loss).
- Touch containers/stacks of other projects, or kill processes that are not this app.
- Delete user data, settings or databases when reinstalling a non-Docker app.
- Commit to main/master; force-push shared branches.
- Commit `.env`, secrets, credentials, or build output.
- Bypass `gh` auth failures or non-GitHub remotes.

## Cheat-sheet
```
docker compose ls
docker compose -p P -f F1 -f F2 config
docker compose -p P -f F1 build [--no-cache]
docker compose -p P -f F1 up -d --force-recreate --remove-orphans
docker compose -p P -f F1 ps
docker compose -p P -f F1 logs --tail 100 SVC
git switch -c feat/x ; git add <files> ; git commit -m "feat: x"
git push -u origin HEAD
gh pr create --base main --title "feat: x" --body "..."
```
