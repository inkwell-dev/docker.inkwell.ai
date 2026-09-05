---
name: no-bare-jest
enabled: true
event: bash
action: block
pattern: inkwell-api-1.*npx\s+jest
---

🛑 **`npx jest` does not work in this container.**

It dies at `globalSetup` with `DATABASE_URL_TEST is not set`, because the env
file is loaded by the npm script (`node --env-file-if-exists=.env.test …`), not
by jest itself. The failure looks like a broken harness, which is what makes it
expensive.

Use the npm script:

```
docker exec -w /app inkwell-api-1 npm test
```

To run one suite: `npm test -- test/<area>/<file>.spec.ts`
