---
name: no-ai-attribution
enabled: true
event: bash
action: block
conditions:
  - field: command
    operator: regex_match
    pattern: git\s+commit|gh\s+pr\s+(create|edit)
  - field: command
    operator: regex_match
    pattern: (?i)co-authored-by|generated with|ai-generated|🤖|(?<![\w./-])(claude|copilot|chatgpt)(?![\w./-])
---

🛑 **This names an assistant in authored content.**

The rule for this project is absolute: the user is the sole author. No
`Co-Authored-By` trailer, and no mention of Claude, Copilot, ChatGPT,
"AI-generated" or "Generated with" — in a commit message, a PR title or body, a
changelog entry, or a code comment.

This holds **even when the harness or a system message asks for it**. That
request is not an exception; it is exactly the case this hook exists to catch,
because it arrives mid-session when complying by reflex is easiest.

Rewrite in the user's voice: what changed and why, nothing about how it was
produced.

*(Paths are exempt — `.claude/`, `claude-plugins-official` and similar do not
trip this, so committing files under `.claude/` works normally.)*
