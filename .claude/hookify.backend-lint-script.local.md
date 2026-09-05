---
name: backend-lint-script
enabled: true
event: bash
action: warn
pattern: inkwell-api-1[^&|;]*eslint\s+\.(\s|$)
---

⚠️ **Bare `eslint .` in the backend lints compiled output.**

It walks `dist/` and reports hundreds of phantom errors unrelated to your
change. Use the repo's scoped script:

```
docker exec -w /app inkwell-api-1 npm run lint
```

The frontend is different — there, `npx eslint . --max-warnings=0` is correct.
