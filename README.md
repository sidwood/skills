# Agent Skills

A collection of skills for agents, focused on software engineering and knowledge management.

## Install

Requires [GNU Stow](https://www.gnu.org/software/stow/).

From within this repo:

```bash
mkdir -p ~/.claude/skills
stow -d .. -t ~/.claude/skills --ignore='README\.md' --ignore='AGENTS\.md' skills
ln -sf "$(pwd)/AGENTS.md" ~/.claude/CLAUDE.md
```

Re-run the stow command after adding new skills — Stow is idempotent for existing links and additive for new ones.

## Planned

### Software Engineering

Skills that improve agent capabilities across the development lifecycle:

- **Planning** — breaking down problems, scoping work, creating implementation plans
- **Design** — system architecture, API design, technical decision-making
- **Development** — writing, reviewing, and refactoring code

### Note-Taking & Knowledge Management

Skills for capturing and organising notes, particularly with tools like Obsidian:

- **Note capture** — structuring and formatting notes from conversations
- **Knowledge linking** — connecting ideas across notes and projects
