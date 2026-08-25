---
name: canvas-kanban
description: Use when creating, editing, repairing, or bootstrapping a canvas kanban board for agent fleet work — .canvas.tsx ticket boards, ticket cards, done-ticket ledgers, board-state JSON, or standing orders on a board.
---

# Canvas Kanban

Keep one machine-readable store as the truth for ticket state and render the
board from it, so a coordinator can operate the board by pattern-matching
fields instead of parsing prose.

## The file trio

1. `<board>.canvas.tsx` — the human view, a Cursor canvas importing from
   `cursor/canvas`. Read `~/.cursor/skills-cursor/canvas/SKILL.md` for SDK
   components and design rules before restyling.
2. `<board>.canvas.data.json` — UI state only (column overrides, selection,
   filters). Never coordination truth: a card's real column is the tsx value
   unless overridden here, so remove stale overrides when cards move or
   leave.
3. The project's fleet config JSON — machine truth for phases, tips,
   verdicts, and bounce counts (see the fleet-coordinator skill). When the
   board and the config disagree, the config plus live git wins; fix the
   board.

## Workflow

1. Give every ticket card: id, ticket, title, column, stream, problem, and
   done as checkable acceptance criteria — a reviewer must be able to answer
   each line yes or no. A done paragraph nobody can tick degrades the
   acceptance bar to "zero findings", which never converges.
2. Add where applicable: blockedBy, correction (structured verdict notes),
   rulings, workingAgents, assignedReviewer, implementor, chips.
3. Column semantics: parked (needs a human ruling), blocked (open blockers),
   ready, current, review. Blocked cards auto-promote to ready when their
   blockers leave the board — park explicitly when a human must decide, or
   the board will offer the card for dispatch.
4. On land, move the card from the active tasks array to the done ledger:
   branch, commit range, implementer, reviewer, verdict notes, landed flag,
   checkout disposition.
5. Keep policy out of card prose: standing orders hold board-wide facts and a
   pointer to the coordinator rulebook; delete orders that died with their
   ticket instead of accreting them.
6. After every edit, type-check the canvas (`tsc --noEmit` with the canvases
   tsconfig) against the installed `cursor/canvas` types before handing it
   back.

## Rules

- Canvas strings are single-quoted TypeScript: no bare apostrophes in card
  text — reword, or use a typographic apostrophe.
- Chips replace default chips when set; keep model chips (workingAgents) as
  the only signal of live agents.
- Structured fields over prose: verdicts, deferrals, bounce counts, and
  rulings must survive being read by a program.
