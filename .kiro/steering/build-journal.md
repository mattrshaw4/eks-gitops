---
inclusion: always
---

# Build Journal Rule

This project becomes a Medium article and a LinkedIn post. The best material comes from things that go wrong.

Whenever any of these happen, append an entry to `docs/build-log.md` before moving on:
- A command, `terraform apply`, or deploy fails
- Something works differently than the docs or Matt expected
- A design decision is made between two real options
- Something recovers on its own (self-healing, Argo CD auto-sync, drift correction)

Entry format:

```
## YYYY-MM-DD HH:MM: <short title>
**What I expected:**
**What happened:** (paste the exact error or output, trimmed)
**Root cause:**
**Fix:**
**Kitchen version:** (optional, one line, leave blank for Matt to fill)
```

Keep entries factual and short. Do not write article prose here; that happens later.
