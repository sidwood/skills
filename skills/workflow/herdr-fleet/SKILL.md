---
name: herdr-fleet
description: Use when the user asks to start, run, inspect, or coordinate a fleet of Claude Code, Codex, OpenCode, or Grok Build agents in a Herdr session.
---

## Workflow

1. If `HERDR_ENV=1`, keep inherited session/caller IDs. Otherwise run
   `herdr session list --json`, choose one, and export `HERDR_SESSION=<name>`;
   never default when unclear. `herdr --session <name>`
   creates/attaches an interactive session.
2. Run `herdr api snapshot`. Reuse requested workspace or create one:
   `herdr workspace create --cwd <path> --label <label> --no-focus`. Use only
   JSON-returned IDs.
3. Run `git bc-add -h`; create/reuse one branch checkout/work item. Use it as
   every implementer/reviewer tab's `--cwd`; one writer/checkout. Add checkouts
   only for independent workstreams.
4. For each unique `[a-z][a-z0-9_-]{0,31}` name, run
   `herdr tab create --workspace <workspace-id> --cwd <path> --label <name> --no-focus`
   and take pane ID from `.result.root_pane.pane_id`.
5. Run at most one live wrapped agent/kind via
   `herdr pane run <pane-id> "<recipe>"`:

   ```sh
   caveman wrap --workflow glm-5_3 opencode --model opencode-go/glm-5.3 --auto
   caveman wrap --workflow opus-5-xhigh claude --dangerously-skip-permissions --model opus --effort xhigh
   caveman wrap --workflow sol-5_6-xhigh codex --dangerously-bypass-approvals-and-sandbox -m gpt-5.6-sol -c model_reasoning_effort=xhigh
   # Grok Build: direct; generic Caveman rejects its OAuth
   grok --model grok-4.6 --reasoning-effort xhigh --always-approve
   ```

   After detection, run `herdr agent rename <pane-id> <name>`. Start same-kind
   extras/wrap failures directly, passing recipe arguments after its harness:
   `herdr agent start <name> --kind <kind> --pane <pane-id> -- <agent-args>`.
   Report uncompressed agents.

6. Prompt ready, independent agents concurrently:
   `herdr agent prompt <name> <task>`. Wait via
   `herdr agent wait <name> --timeout <ms>`; prompt dependents after prerequisites
   settle. Settled = `idle`, `done`, or `blocked`; `unknown` is incomplete.
7. Blocked/failed/unclear: run `herdr agent get <name>` and
   `herdr agent read <name> --source recent-unwrapped --lines 120`; follow up
   via `agent prompt` or logical `agent send-keys`.

Finish when all requested agents are detected, tasked, settled, and their
result/blocker reported.

## Rules

- Close only created resources unless asked. On syntax drift,
  inspect `herdr --help` and relevant group; binary wins.
