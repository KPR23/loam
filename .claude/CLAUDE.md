# Loam

## Commits

- Author every commit as the repository owner (the configured git user), never as Claude.
- Don't add AI attribution to commit messages: no `Co-Authored-By:`, `Claude-Session:` or similar trailers.

## Migrations

- Create migrations with `supabase migration new <name>`; never hand-write the timestamp prefix. Supabase keys migrations by that prefix alone, so two files sharing it break `db push` even when the names differ.

## Skills

- `.claude/skills/swiftui-pro` is vendored from twostraws/swiftui-agent-skill (pinned in `skills-lock.json`) with local changes: the nested `skills/` copy and `.claude-plugin/` manifest are removed, and `references/api.md` only requires the `Tab` API on iOS 18+. Re-running `npx skills add` overwrites these, so reapply them after updating.
