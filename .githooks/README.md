# Git hooks (optional)

This repo ships hook sources under `.githooks/`. To activate locally (does not use `core.hooksPath`):

```bash
cp .githooks/prepare-commit-msg .git/hooks/prepare-commit-msg
chmod +x .git/hooks/prepare-commit-msg
```

`prepare-commit-msg` strips `Co-authored-by: Cursor <cursoragent@cursor.com>` if the agent harness injects it.
