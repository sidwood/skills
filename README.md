# Agent Skills

Personal, reusable Agent Skills organized by purpose and installed globally for
the coding agents I use.

## Catalog

The repository keeps a visible taxonomy while the installer exposes every
skill under its unqualified name.

| Category | Skills |
| --- | --- |
| Product | `prd-review`, `prd-to-plan`, `to-issues`, `to-prd`, `to-questionnaire`, `to-spec` |
| Engineering | `bug-report`, `codebase-design`, `commit-message`, `domain-modeling`, `improve-codebase-architecture`, `migrate-to-shoehorn`, `prototype`, `ubiquitous-language` |
| Workflow | `compress`, `defuddle`, `grilling`, `handoff`, `research`, `teach`, `wait-what`, `zoom-out` |
| Authoring | `compress-a-skill`, `humanizer`, `to-skill`, `verify-compression`, `writing-for-agents` |
| Creative | `rpg-scenario-beats` |

Canonical skills live at `skills/<category>/<name>/`. Installed links are flat,
so `skills/engineering/commit-message` is installed as `commit-message`.

## Install

```bash
brew install pre-commit
./install.sh
```

The installer validates that every directory matches the `name` in its
`SKILL.md`, refuses duplicate names, enables the repository commit-message
hook, and creates repository-owned links in three global locations:

| Location | Agents |
| --- | --- |
| `~/.agents/skills` | Codex, Cursor, Kimi Code, OpenCode, Pi |
| `~/.claude/skills` | Claude App Code tab, Claude Code |
| `~/.grok/skills` | Grok |

Foreign files and links are left untouched. Re-running the installer is safe.
The installer also migrates this repository's old links out of
`~/.codex/skills`. Global instruction files remain owned by each harness or
the user's dotfiles.

The repository-managed Git hooks run two validation stages:

- `pre-commit` delegates staged-file checks to `.pre-commit-config.yaml`,
  currently CSpell, ShellCheck, Gitleaks, and skill-catalog validation.
- `commit-msg` enforces the repository's commit-message convention.

The first pre-commit run downloads and caches the pinned hook environments.

### Hermes

Hermes keeps ownership of `~/.hermes/skills`. The installer does not place
links there. Instead, it adds this repository's canonical `skills/` directory
to `skills.external_dirs` in `~/.hermes/config.yaml`.

Hermes can edit skills found in an external directory when explicitly asked to
use its skill-management actions. Set `skills.write_approval: true` in the
Hermes configuration if every such write should require approval.

If an existing `skills.external_dirs` value is a scalar rather than a YAML
list, the installer leaves it untouched and prints the exact directory to add.

## Uninstall

```bash
./uninstall.sh
```

Uninstall removes only links and the Hermes configuration entry managed by
this repository. Foreign skills and configuration remain in place.

## Tests

The installer and uninstaller have a
[Bats](https://github.com/bats-core/bats-core) test suite that runs entirely in
temporary directories.

```bash
brew install bats-core
./tests/run.sh
```
