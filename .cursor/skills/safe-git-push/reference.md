# This-repo patterns for safe-git-push

## Must stay gitignored (live copies; never `git add -f`)

- `quay-secret.yaml`
- `minio-s3-secret.yaml`
- `.env`

## Not treated as secrets

Intentional template placeholders and non-literal values are fine in tracked files, for example:

- `CHANGE_ME_*`, `REPLACE_WITH_*`, `<base64(...)>`, `<password>`, etc.
- Variable references (`$FOO`, `` `cmd` ``) and bare identifiers used as code (`token=token`)

## Out of scope

Lab/cluster hostnames (e.g. `*.opentlc.com`) and “must use placeholder domain” rules are **not** enforced. Only sensitive credentials/tokens/keys block a push.
