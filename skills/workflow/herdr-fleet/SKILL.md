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
5. Start each agent direct via `herdr agent start <name> --kind <kind> --pane <pane-id> --timeout 120000 -- <agent-args>`. Look up kind and args in `surface-fleet-streams.json` `agentRecipes`. Never use Caveman wrap or `herdr pane run` for agent recipes.

   ```sh
   # sol-xhigh-implementer
   herdr agent start sol-xhigh-implementer --kind codex --pane <pane-id> -- \
     --dangerously-bypass-approvals-and-sandbox -m gpt-5.6-sol -c model_reasoning_effort=xhigh
   # opus-xhigh-implementer
   herdr agent start opus-xhigh-implementer --kind claude --pane <pane-id> -- \
     --dangerously-skip-permissions --model opus --effort xhigh
   # opus-max-reviewer / opus-max-reviewer-2
   herdr agent start opus-max-reviewer --kind claude --pane <pane-id> -- \
     --dangerously-skip-permissions --model opus --effort max
   # sol-max-reviewer
   herdr agent start sol-max-reviewer --kind codex --pane <pane-id> -- \
     --dangerously-bypass-approvals-and-sandbox -m gpt-5.6-sol -c model_reasoning_effort=max
   # Grok Build (when used)
   herdr agent start <name> --kind grok --pane <pane-id> -- \
     --model grok-4.6 --reasoning-effort xhigh --always-approve
   ```

6. Prompt ready, independent agents concurrently:
   `herdr agent prompt <name> <task>`. Wait via
   `herdr agent wait <name> --timeout <ms>`; prompt dependents after prerequisites
   settle. Settled = `idle`, `done`, or `blocked`; `unknown` is incomplete.
7. When an agent settles (`idle`, `done`, or `blocked`): run
   `herdr agent read <name> --source recent-unwrapped --lines 200` **before**
   any `herdr tab close`. Capture REVIEW-READY, `APPROVE: yes/no`, and findings.
   Never close a tab until read succeeds and feedback is recorded — closing first
   destroys the verdict (T095 sol-max-reviewer-2 incident). Then dispatch,
   bounce, or land; only then tear down the tab.
8. Blocked/failed/unclear: run `herdr agent get <name>` and
   `herdr agent read <name> --source recent-unwrapped --lines 200`; follow up
   via `agent prompt` or logical `agent send-keys`.

Finish when all requested agents are detected, tasked, settled, and their
result/blocker reported.

## Rules

- **Read before close:** never `herdr tab close` until `herdr agent read` succeeds
  and REVIEW-READY / APPROVE / failure is captured for the ticket.
- Close only created resources unless asked. On syntax drift,
  inspect `herdr --help` and relevant group; binary wins.
