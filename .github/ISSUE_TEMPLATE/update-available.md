---
name: Update available (prod)
about: A newer image set is published and prod is behind — opened automatically by 230 · Image Update
title: "Update available for prod: sha-XXXXXXX"
labels: update-available
---

<!--
230 · Image Update opens this issue automatically when the core publishes a new
image set and prod's release catalog is behind. dev updates on its own; prod
waits for a human. Use this template only if you need to request a prod update
by hand (for example after the automatic issue was closed by mistake).
-->

| Image | Reference |
|---|---|
| api | `docker.io/<namespace>/cna:api-sha-XXXXXXX@sha256:<digest>` |
| web | `docker.io/<namespace>/cna:web-sha-XXXXXXX@sha256:<digest>` |
| migrator | `docker.io/<namespace>/cna:migrator-sha-XXXXXXX@sha256:<digest>` |

**To apply:** open **210 · Deploy → Run workflow**, choose `environment: prod`,
`deploy_mode: release`, the `ai_mode` prod is currently deployed with (see
`.deployment-catalog/prod/latest.json` → `ai_mode`; never change it in an image
update), paste the three image references, and run. The `hub` environment
approval gate applies. Close this issue once the prod release catalog shows the
new `sha_tag`.
