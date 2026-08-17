# Diagnosing skills

Consult when auditing, trimming, or debugging a skill. Each entry: failure mode + cure. Work through all against the skill in front of you; a healthy skill survives every check.

Root virtue is **predictability** — agent takes the same *process* every run. Every failure below breaks that.

## Pruning failures

- **Sediment** — stale layers pile up (adding feels safe, removing risky); you core through dead lines to find live ones. *Cure:* prune every edit; delete anything no longer relevant.
- **No-op** — line the model already obeys by default -> pay load, say nothing. Test: *does it change behavior vs default?* Weak leading word (`be thorough` when agent's already thorough-ish) is a no-op; fix with a stronger word (`relentless`), not more words.
- **Duplication** — same meaning in >1 place. Costs maintenance + tokens, inflates apparent importance. *Cure:* one **single source of truth** per meaning. (Repeating a *leading word* isn't duplication — that repeats a token to build meaning, on purpose.)
- **Sprawl** — too long even when every line is live/unique. *Cure:* disclose reference behind conditional pointers; split by branch/sequence so each path carries only its own.
- **Relevance** — line no longer bears on what the skill does (never did, or went stale). Shorter skills stay relevant cheaper. Check every line.

## Steering failures

- **Premature completion** — ending a step before it's done, attention slipping to *being done*. Needs steps to occur. *Cure, in order:* (1) sharpen the **completion criterion** -> checkable ("every modified model accounted for") so agent tells done from not-done; (2) only if irreducibly fuzzy *and* you see the rush, hide later steps by splitting across a real context boundary (subagent or user-invoked hand-off; inline call leaves them in context, hides nothing).
- **Thin legwork** — agent offloads work it should do (reading files, exploring code) because nothing demands otherwise. *Cure:* raise demand with a leading word (`comprehensive`, `exhaustive`) or a completion criterion requiring the work complete.
- **Negation** — steering by prohibition drags the banned behavior into context -> *more* available. *Cure:* prompt the positive; name the target so the ban goes unspoken. Keep a prohibition only as a hard guardrail, paired with the positive target.

## Invocation failures

- **Wrong load** — rare skill kept model-invoked pays permanent context load for reach it doesn't need. *Cure:* make it user-invoked in every target harness (`disable-model-invocation: true` plus Codex's `allow_implicit_invocation: false`); reach it explicitly by name or selector.
- **Weak trigger** — must-have skill/reference behind a vague pointer fires unreliably. Pointer *wording*, not target, decides when agent reaches it. *Cure:* sharpen wording (description or in-body pointer) before restructuring.
- **Router overload** — too many user-invoked skills for the human to remember. *Cure:* a router skill naming the rest + when to reach each.

## Vocabulary

Shared terms so the team reasons about skills the same way.

| Term | Meaning |
| --- | --- |
| **Context load** | Cost a model-invoked description imposes every turn (tokens + attention). |
| **Cognitive load** | Cost a user-invoked skill imposes on the human, who must remember it. |
| **Branch** | A distinct way the skill is invoked; runs take different paths. |
| **Completion criterion** | Condition telling agent a step is done. Strongest: checkable *and* exhaustive. |
| **Leading word** | Pretrained concept the agent thinks with; repeated as a token, anchors behavior cheaply. |
| **Progressive disclosure** | Moving reference out of `SKILL.md` behind a conditional pointer to keep the top legible. |
| **Single source of truth** | Each meaning lives in exactly one authoritative place. |

*Vocabulary + failure-mode framing draw on Matt Pocock's `writing-great-skills` glossary.*
