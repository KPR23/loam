# Loam

## Commits

- Author every commit as the repository owner (the configured git user), never as Claude.
- Don't add AI attribution to commit messages: no `Co-Authored-By:`, `Claude-Session:` or similar trailers.

## Skills

- `.claude/skills/swiftui-pro` is vendored from twostraws/swiftui-agent-skill (pinned in `skills-lock.json`) with local changes: the nested `skills/` copy and `.claude-plugin/` manifest are removed, and `references/api.md` only requires the `Tab` API on iOS 18+. Re-running `npx skills add` overwrites these, so reapply them after updating.
