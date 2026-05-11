# tedplatform-publish skill

Claude skill that teaches an AI assistant how to orchestrate the
Tedplatform MCP tools to publish an application. Triggers on
publish/deploy/yayınla keywords in conversations that reference
Tedplatform (or `tederga.org` hostnames).

## Install (Claude Code)

```bash
mkdir -p ~/.claude/skills/
cp -r tedplatform-publish ~/.claude/skills/tedplatform-publish
```

Then restart Claude Code. The skill auto-loads when its trigger
description matches the conversation.

## Install (Claude Desktop — preview)

Skills in Claude Desktop are not yet GA. Fallback: rely on the
`tedplatform_help` MCP tool, which Claude can call to fetch the same
orchestration guide on demand. This skill bundle is forward-compatible
and will plug into Claude Desktop's skill system when it ships.

## What the skill does (vs. the MCP tools)

- The **MCP server** (`tedplatform`) exposes ~20 atomic tools: things
  like `tenant_onboard`, `db_provision`, `app_expose`. Each tool's
  description says **what it does**.
- This **skill** teaches Claude **when to call them, in what order, and
  what to do when they fail**. Without the skill, Claude can usually
  figure out the right tool but fumbles the sequence (e.g. calling
  `db_provision` before `tenant_onboard`, missing the Redis dep in the
  user's `package.json`, or not knowing about the `confirm=true` safety
  on `tenant_offboard`).

## Updating

Edit `SKILL.md`. The YAML frontmatter's `description` controls when the
skill auto-loads — be specific about triggers and counter-examples
(`SKIP when ...`) to avoid false positives.

After editing, recopy into `~/.claude/skills/` (or symlink if you want
edits live without recopy).
