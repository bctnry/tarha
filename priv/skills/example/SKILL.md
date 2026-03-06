---
description: Example skill demonstrating the skill system
always: true
requires:
  bins: []
  env: []
---

# Example Skill

This is an example skill that shows how the skill system works.

## Purpose

Skills are markdown files that teach the agent how to use specific tools or perform certain tasks.

## Structure

Each skill has:
- **Frontmatter**: YAML metadata with `description`, `always`, and `requires`
- **Content**: Markdown explaining how to use the skill

## Requirements

Skills can specify requirements:
- `bins`: Required CLI tools
- `env`: Required environment variables

If requirements aren't met, the skill is marked as unavailable.
