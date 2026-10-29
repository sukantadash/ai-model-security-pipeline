---
name: safe-git-push
description: >-
  Scans the git repo for sensitive data that is unsafe to push (credentials,
  tokens, private keys, tracked secret files), remediates when possible, asks
  for review when anything changed, and pushes only when the scan is clean. Use
  when the user asks to push, git push, publish the repo, check if it is safe
  to push, or to validate secrets before committing or pushing.
---

# Safe git push

Validate tracked (and staged) files for **sensitive information** only (live
credentials, tokens, private keys, dockerconfig auth, secret files that must
stay gitignored). Do **not** enforce cluster-domain placeholders or require
`CHANGE_ME_*` / `REPLACE_WITH_*` tokens in tracked files.

Take action on findings. **If you changed anything, stop and ask for review. If the scan is clean, push.**

Never print secret values, tokens, passwords, or dockerconfig `auth` fields. Report path, kind, and line only.

## Workflow

Copy and track:

```
Safe git push:
- [ ] Scan
- [ ] Remediate blocking findings (if any)
- [ ] Re-scan
- [ ] Review gate or push
```

### 1. Scan

Run the skill scanner from the repo root (prefer the project copy when present):

```bash
python3 .cursor/skills/safe-git-push/scripts/scan_repo.py
```

If that path is missing:

```bash
python3 ~/.cursor/skills/safe-git-push/scripts/scan_repo.py
```

Also apply [reference.md](reference.md) when it exists in this repo.

Read `git status`, `git diff`, and `git diff --cached`. Confirm `.gitignore` still lists local secret files. Do not `git add -f` gitignored secrets.

Exit `0` / `"ok": true` means no blocking findings. `"info"` (local gitignored secrets) does **not** block push.

### 2. Take action on blocking findings

| `fix` / kind | Action |
|--------------|--------|
| `unstage_and_gitignore` | `git restore --staged -- <file>` and keep it in `.gitignore`. |
| `gitignore` | Add the filename to `.gitignore`. Do not commit the secret file. |
| `restore_placeholder` / filled secret | Restore a non-secret placeholder or remove the live value; do not invent a real password. |
| token / private key / no `fix` | Do not guess. Quote path+line, ask the user how to handle it. Do not push. |

Never commit live credentials “just this once”. Never skip hooks.

### 3. Re-scan

After any edit, run `scan_repo.py` again. Repeat until `ok` is true **or** a finding cannot be auto-fixed.

### 4. Review gate — if you changed files

If the working tree or index differs from what you started with **because of remediations**:

1. Show a short list of files you changed and why (no secret values).
2. **Stop. Ask the user to review.** Do not commit. Do not push.
3. After they approve, they may ask you to push; then start this skill from step 1.

### 5. Push — only if the scan is clean and you did not remediate

When `"ok": true` and you did **not** modify files in this run:

1. If there is nothing to push (`git status` clean and branch not ahead): say so and stop.
2. If there are uncommitted changes the user already intended to publish: stage **non-secret** files, commit (follow the repo’s commit-message style; never add gitignored secrets), then push.
3. If the branch is already committed and ahead of the remote: `git push -u origin HEAD`.
4. Do not force-push `main` or `master`. Do not `--no-verify`.

If push fails (auth, no remote, rejected), report the error. Do not rewrite history.

## Do not

- Print or echo secret values
- `git add -f` `quay-secret.yaml`, `minio-s3-secret.yaml`, `.env`, or kubeconfigs
- Treat intentional template placeholders (`CHANGE_ME_*`, `REPLACE_WITH_*`, `<base64(...)>`) as secrets
- Block push solely because a lab/cluster FQDN or non-secret placeholder is present
- Push after you just rewrote secrets without user review
