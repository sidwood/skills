# Agent Skills

This repo is the single source of truth, and install should expose these repo skills to both Claude and Codex.

## Install

Requires [GNU Stow](https://www.gnu.org/software/stow/).

```bash
./install.sh
```

Re-run after adding new skills — Stow is idempotent for existing links and additive for new ones.

The installer symlinks this repository's skills into:

- `~/.claude/skills`
- `~/.codex/skills`

Existing skills installed elsewhere are left untouched. They are not imported into this repository, and they are not exposed to Claude by this installer.

## Uninstall

```bash
./uninstall.sh
```

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
