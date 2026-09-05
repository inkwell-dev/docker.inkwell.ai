---
name: skip-db-push-check
enabled: true
event: bash
action: warn
pattern: SKIP_DB_PUSH\s*=\s*1
---

⚠️ **`SKIP_DB_PUSH=1` is only safe when the schema has not changed this session.**

It skips the schema push, so a table or enum value you just added never reaches
`inkwell_test`, and every spec touching it fails on a missing relation — which
reads as a broken harness rather than a missing table.

Touched `src/database/schema/` or added a migration? Drop the flag.
