---
name: refresh-after-changes
description: >-
  After ANY task that changed files in this repo, rebuild / recompile /
  restart / redeploy-local so the change is actually live, then verify it.
  Covers dev servers (hot reload), Docker apps (local Docker Desktop or a
  documented remote host), native Windows/desktop apps (exe, .NET, Tauri,
  Electron, tray apps, services, scheduled tasks), CLIs, MCP servers,
  browser extensions and static sites. Use at the end of every task that
  edited code, config, Dockerfiles or assets; skip only for docs/comment-only
  changes and say so.
author: "Armin Dashti"
uuid: 4f6a2c1e-9b3d-4e7a-8c52-1d0e7b9a3f61
---
# Refresh After Changes

## When

- End of EVERY task that created/edited/deleted files other than pure docs (`*.md`, comments, `.cursor/**`, `AGENTS.md`).
- Before saying "done". A change that compiles but is not running is not done.
- Skip only when nothing executable changed; then report: "Refresh skipped: docs/comments only."

## How

1. **What changed**: `git status --porcelain` + `git diff --stat`. Map files to the affected app(s)/service(s) (e.g. `*-api/`, `*-webui/`, `src-tauri/`, `Dockerfile`, `docker-compose*.yml`, `package.json`).
2. **How does it run now?** Check before acting, a repo can have several modes (dev server + Docker + installed exe):
   - Dev server: `Get-NetTCPConnection -State Listen -LocalPort <port>`; `Get-Process node,vite,go,dotnet -EA 0`.
   - Docker local: `docker ps --format "{{.Names}}\t{{.Image}}\t{{.Status}}"`; `docker compose ls`.
   - Native app: `Get-Process <name> -EA 0 | select Name,Path,StartTime`; `Get-Service *<name>*`; `Get-ScheduledTask *<name>*`.
   - Repo CLI / scripts: `<repo> rebuild`, `scripts\reinstall*.ps1`, `run-*.ps1` (see "This repo"). Prefer the repo's own lifecycle CLI/script over hand-rolled commands.
3. **Refresh** with the table below. Only the affected service/app.
4. **Verify** (mandatory), then **fix** anything your change broke and repeat 3-4.
5. **Report**: what was refreshed, exact command, verification result (exit code, container/image id + created time, process start time/version, URL status).

| Kind | Refresh (PowerShell) | Verify |
|------|----------------------|--------|
| Vite/Vue/React dev server running | Nothing; HMR picks it up. Config/deps change (`vite.config.*`, `package.json`, `.env`) -> restart that dev server only | Page loads, no overlay/console errors; terminal shows hmr update |
| Frontend, no dev server | `npm run build` (or `pnpm build`) in that package | exit 0, `dist/` updated |
| Node/TS (CLI, MCP server, NestJS) | `npm run build`; restart the running process (`tsx watch`/`nest --watch` self-reload). MCP server: rebuild `dist`, then tell user to reload MCP in Cursor if it's registered there | exit 0; process restarted; tool/endpoint responds |
| Go | `go build ./...` then restart the running binary/container | exit 0; new process StartTime; endpoint 200 |
| Rust / Tauri | `cargo build` (`--release` if the installed app uses release); Tauri: `npm run tauri build` or the repo install script | exit 0 |
| .NET (console/WinForms/WPF/ASP.NET) | `dotnet build -c Debug` (or `msbuild <sln>`); ASP.NET on IIS/IIS Express: build, then recycle the app pool (`Import-Module WebAdministration; Restart-WebAppPool <pool>`) or touch `web.config` | exit 0, 0 errors; page responds |
| Python | deps changed -> `pip install -e .` / `uv sync`; restart uvicorn/service (`--reload` handles code) | process up; endpoint 200 |
| **Docker app (local)** | `docker compose -f <file> -p <project> up -d --build <service>` (use the repo's CLI/script if it has one) | `docker ps` shows container Up/healthy; `docker inspect -f "{{.Image}} {{.Created}}" <ctr>` = new image, created just now; `docker logs --tail 50 <ctr>` clean; URL returns 200 |
| **Docker app (remote)** | Only if repo docs say remote is the normal dev loop, or user asked: `ssh <host> "cd <dir> && docker compose up -d --build <service>"` after syncing code the documented way | same checks via ssh + curl the URL |
| **Native OS app** (exe, .NET, Tauri/Electron, tray app) | Build -> stop running instance (`Stop-Process -Name <proc>`; ask first if user may have unsaved work) -> if it runs from an install dir (`%LOCALAPPDATA%\<App>`, `Program Files`), reinstall/copy the new build via the repo's install script -> relaunch (`Start-Process <path>`) | new process running from the expected path; StartTime is now; file version/hash = new build; app responds |
| **Windows service / scheduled task** | Build -> `Stop-Service <svc>` -> copy/install -> `Start-Service <svc>`; task: `Stop-ScheduledTask`, update, `Start-ScheduledTask` (admin may be needed) | `Get-Service` Running; task LastTaskResult 0; logs clean |
| Browser extension | `npm run build`; tell user to click Reload in `chrome://extensions` (can't be done headless) | build exit 0, `dist/` manifest version |
| Static site / HTML / skills / docs repo | Nothing to build; if a local preview server runs, refresh it | file served / page renders |
| nginx / reverse proxy config | `docker exec <ctr> nginx -t` then `docker exec <ctr> nginx -s reload` | `-t` ok, URL 200 |

## Always

- Prefer hot reload when a dev server is already running; never start a duplicate (check the port/process first).
- Restart only the affected service/container/app, not the whole stack.
- Start long-running servers in the background and poll their output; never block the session.
- Use the repo's own CLI/scripts and documented ports, compose project names and networks.
- Fix build/type errors your change introduced before finishing; leave pre-existing failures alone and report them.
- If a refresh needs admin/UAC, or would close an app the user is using, say so and ask.

## Never

- Destructive commands: `docker volume rm`, `docker system/volume/image prune`, `compose down -v`, `--remove-data`, DB drop/reset/migrate-down, `git reset/clean/push`, deleting user data.
- Deploy to production or remote servers (incl. `ssh` hosts) unless repo docs say that's the normal dev loop or the user asked.
- Claim "done" with only a successful build when the app is supposed to be running.
- Reload shared infra that drops other users (HAProxy, VPN, prod nginx) without explicit approval.

## Example

Changed `foo-webui/src/App.vue` and `foo-api/handlers.go`:
- webui: Vite dev server on 5173 already running -> HMR, page OK.
- api: `docker compose -p foo up -d --build foo-api` -> container recreated (image created 12:04), `/api/health` 200.
Report: "Refreshed foo-webui via HMR, rebuilt foo-api container; both verified."

## This repo (roust)

Kind: Rust API + Vue webui, Docker + Windows install scripts. `scripts\reinstall-win11.ps1` (check it doesn't wipe data) or `docker compose up -d --build` in `roust-api` / `roust-webui`; `scripts\selfcheck-win11.ps1` to verify.
