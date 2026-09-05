---
name: verify-in-container
enabled: true
event: bash
action: warn
pattern: ^(?!.*docker\s+(compose\s+)?exec).*(npx\s+(tsc|eslint|jest)|npm\s+(run\s+)?(lint|build|test))
---

⚠️ **This looks like a host-side verification command.**

`node_modules/` is an **empty volume mount** in both app repos. A check that
appears to run on the host has silently not run — it does not fail loudly, it
just tells you nothing.

```
docker exec -w /app inkwell-api-1 npx tsc --noEmit    # backend
docker exec -w /app inkwell-web-1 npx tsc --noEmit    # frontend
```

Capture the exit code explicitly (`echo "exit: $?"`) rather than reading
stdout — a gate reported green while it was red is how a ticket's type errors
once shipped past review.
