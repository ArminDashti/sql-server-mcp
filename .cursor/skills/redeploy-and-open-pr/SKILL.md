---
name: redeploy-and-open-pr
description: >-
  Use after ANY code change in a repo. If the app is Docker-based, rebuild,
  re-create and re-run it with docker compose so the latest changes are live
  WITHOUT losing data (volumes and bind mounts preserved), verify health, then
  commit on a feature branch and open a GitHub PR with gh.
author: "Armin Dashti"
uuid: 103e2b4b-ebe2-4d05-ac38-d92fada952ca
---

# Redeploy and open a PR

Run after every code change. Order: detect -> rebuild -> verify -> PR -> report.

## 1. Detect Docker
- Look in repo root and deploy folders (`deploy/`, `docker/`, `infra/`, `ops/`) for `compose.yaml`, `compose.yml`, `docker-compose.yml`, `docker-compose.*.yml`, `Dockerfile`.
- None found -> skip to step 3.

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

## 3. Pull Request
1. Preconditions: `git remote get-url origin` is GitHub and `gh auth status` succeeds. Otherwise report clearly and STOP (no auth workarounds).
2. Branch: if on default branch (`gh repo view --json defaultBranchRef -q .defaultBranchRef.name`), `git switch -c feat/<short-desc>` (or `fix/<short-desc>`).
3. Stage only relevant files: `git add <paths>`; check `git status` / `git diff --cached --stat`. Exclude `.env*`, secrets, credentials, keys, build artifacts, large binaries.
4. Commit (conventional commits): `git commit -m "feat(scope): short summary"`.
5. Push: `git push -u origin HEAD`.
6. PR: `gh pr create --base <default> --title "<title>" --body "<body>"`
   - Body: Summary of change, How verified, Docker rebuild result (services, status, URLs) or "not Docker-based".
7. Capture the PR URL.

## 4. Final report
- What changed (files, behavior).
- Rebuild result: services + status, URLs/ports (or "skipped: not Docker").
- PR link (or the exact reason it wasn't created).

## Never
- `docker compose down -v`, `docker volume rm`, `docker volume prune`, `docker system prune --volumes`.
- Delete or move bind-mount data dirs; change volume names/paths; rename the compose project (new name = new empty volumes = apparent data loss).
- Touch containers/stacks of other projects.
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
