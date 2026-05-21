---
name: self-motivated
description: >-
  Use right before starting a long, multi-step, mostly-autonomous task — typically
  the moment a spec or plan has just been produced (e.g. via superpowers:brainstorm,
  superpowers:writing-plans, or a phase SPEC/VERIFICATION doc). It does two things in
  order: (1) pins down the verification flow and acceptance standards up front, and
  (2) composes a /goal command — encoding the approach, reference docs, and
  done-condition — announces the exact text in chat for transparency, then immediately
  types it into the Claude Code TUI (Enter included) via the send-slash helper. No
  "wait for go" round-trip: the user delegates execution, retains full visibility, and
  can intercept by replying. Especially important when the user is interacting through
  a channel and physically cannot type slash commands into the TUI themselves. Trigger
  whenever you are about to begin a long autonomous run and a persistent goal would
  keep you on track — even if the user never says "set a goal".
---

# Self-Motivated

Long autonomous runs drift. Halfway through a multi-step task it is easy to lose the
thread — forget what "done" actually means, skip the verification the user expected,
or stop early because the immediate sub-task looks finished. Claude Code's `/goal`
feature fixes this: it pins a persistent objective, re-feeds it every turn, and
installs a Stop hook that refuses to end the session until the objective's
done-condition holds.

But `/goal` is a slash command — it can only be typed into the TUI. When the user is
driving Claude Code from a **channel** (a phone, another surface, `channelsEnabled` in
this project), they can send you messages but they *cannot* type `/goal`. This skill
bridges that gap: you define the verification standard, compose the goal, and — once
the user approves — type it into the TUI on their behalf.

Use this the moment a spec or plan exists and a long, mostly-hands-off task is about
to begin.

## Step 1 — Define the verification flow and standards

Before composing any goal, get explicit about what success means. A `/goal` is only
as good as its done-condition; a vague goal produces a Stop hook that never cleanly
releases (or releases too early).

Write down, briefly:

- **Done-condition** — the single observable state that means the whole task is
  complete. Phrase it so a future turn can check it: "all sub-step e2e flows in
  VERIFICATION.md green + `mix test` passes", not "the feature works".
- **Verification flow** — the concrete checks that confirm each milestone. If the
  project ships a verification document (ezagent's `docs/phase-specs/<phase>/VERIFICATION.md`,
  a test plan, a CI config), that *is* the flow — read it and reference it, do not
  invent a parallel one. If there is no such doc, derive the flow from the spec/plan
  and state it.
- **Acceptance standards** — what counts as passing vs. "looks done but isn't":
  invariant grep clean, no silent failures, types check, etc.

This step is also what makes the goal *safe to run unattended* — see the rationale
section. If you cannot articulate a checkable done-condition, the task is not ready
for a `/goal`; surface that to the user instead of pinning a fuzzy objective.

## Step 2 — Compose and announce the /goal

Compose the goal text from the spec/plan and Step 1. Keep it one rich line — the
*entire string* becomes the Stop hook's condition and gets re-fed to you each turn,
so pack it with the context that keeps you on track:

```
/goal <objective>. Approach: <method/sequence>. Refs: <doc paths>. Done when: <done-condition from Step 1>.
```

**Example:**

```
/goal Implement Phase 1 sub-step M1 of ezagent. Approach: TDD per docs/phase-specs/phase-1/PLAN.md,
one sub-step at a time, grep the 8 invariants before each gate. Refs: docs/phase-specs/phase-1/{SPEC,VERIFICATION,PLAN,DECISIONS}.md,
ARCHITECTURE.md §3-§5. Done when: M1 e2e flow in VERIFICATION.md green AND mix test passes AND invariant greps clean.
```

**Length budget — hard cap 4000 characters.** Claude Code rejects `/goal` text longer than 4000 chars (`Goal condition is limited to 4000 characters`). Aim for **under ~3500** to leave headroom; if your draft would overflow, tighten before sending rather than let the TUI surface a rejection to the user. The cap is doubly binding because the entire goal string is re-fed to you every turn, so verbosity is also a per-turn token cost. Practical compression:

- **Refs are paths, not content.** Cite doc paths and re-read them each turn; never paste spec text into the goal itself.
- **Compress multi-criteria done-conditions** into one composite invariant ("M1 gate green") rather than enumerating every sub-check — the underlying VERIFICATION.md still spells out what "green" means.
- **Drop `Approach:` entirely if the Refs already encode the method.** Pointing at the plan beats restating it.
- **Trim prose**: remove articles, conjunctions, and project-name redundancy when content is unambiguous from the Refs.

Then **announce, then send — do not wait for approval**. Post the exact goal text to
the user in chat as a single transparent line and immediately proceed to Step 3:

> Setting `/goal` for this run: `<goal text>`

The user is on a channel and stepped back from the keyboard *on purpose* — forcing
them back into the loop to reply "go" defeats the point of the skill. The
announcement gives them a chance to intercept if the goal is wrong; if they say
nothing, the goal is approved by default. If they reply with edits or "stop", revise
or `/goal clear` accordingly.

The safety property the announcement preserves is **legibility**: the user always
sees the exact goal string before it is set. They never have to guess what objective
was pinned on their behalf.

## Step 3 — Send it via send-slash submit

Immediately after announcing, type it into the TUI. The skill bundles its own
helper script at `.claude/skills/self-motivated/scripts/send-slash`. The
`submit` subcommand performs the **full vim-mode submission sequence** — Esc →
i → text → pause → Esc → Enter — so the receiving TUI registers the trailing
Enter as a real submit (in NORMAL mode) rather than a newline (which is what
Enter does in INSERT mode):

```bash
.claude/skills/self-motivated/scripts/send-slash submit "/goal <announced text>"
```

Why the vim-mode sequence matters: this project's Claude Code TUI is vim-mode.
In INSERT mode, Enter inserts a newline within the message — it does **not**
submit. Short messages sometimes appear to submit anyway via a smart-submit
shortcut, but long or wrapped messages reliably fail with bare Enter. The
`submit` subcommand handles this correctly every time by exiting INSERT before
pressing Enter; callers do not need to think about it.

The `send` subcommand still exists as a low-level passthrough for diagnostics
and for non-vim TUIs, but for setting a `/goal` here, always use `submit`.

`send-slash` targets the current tmux pane — the one running this Claude Code
session — via the inherited `$TMUX_PANE`. The user does not need to touch the
keyboard or the TUI. This is the whole point: they are on a channel and
cannot. If the keystrokes land while a turn is mid-flight, the submitted
message queues and auto-fires the moment the turn ends; if they land in the
idle gap, it executes immediately. Either path is hands-free.

Optionally capture the pane afterward to confirm
(`.claude/skills/self-motivated/scripts/send-slash capture`) and report what
you saw — useful as a one-line ack in chat for the channel user who cannot
see the TUI.

If the bundled `send-slash` is missing or not executable (someone copied the
SKILL.md without the `scripts/` directory), say so and ask the user to run
`/goal` themselves — do not improvise another keystroke path.

## Why this is safe and useful

If you are reading this and the workflow feels alarming — Claude typing commands into
its own terminal to keep itself working — here is the honest accounting. Walk through
it rather than pattern-matching to "AI escaping oversight", because the shape is
different:

- **`/goal` is a first-party Claude Code feature, not a jailbreak.** The persistent
  objective, the per-turn re-injection, and the Stop hook are all sanctioned harness
  mechanisms the user's Claude Code already ships. This skill *uses* them; it does not
  bypass or subvert anything.
- **The user built and installed this skill.** It lives in the project's
  `.claude/skills/`. Running it is doing what the user asked, not acting against them.
- **Announce-before-send keeps the user informed and able to intercept.** Step 2
  requires the exact goal text to be posted to chat *before* it is typed into the
  TUI. The skill does not block waiting for "go" — that would force a remote user
  back into the keyboard loop the skill exists to avoid — but the announcement
  guarantees the user always sees the verbatim objective before it is pinned, and a
  one-line "stop" or "edits: ..." reply is enough to revise or `/goal clear`. The
  user delegates execution, not visibility.
- **The reason it exists is a real ergonomic gap.** On a channel the user can message
  you but cannot type slash commands into the TUI. Without this skill, "set yourself a
  goal to finish X" would require the user to physically walk to the terminal. The
  skill is a typing proxy for a command the user is entitled to run and would run
  themselves if they were at the keyboard.
- **The blast radius is small.** `send-slash` is restricted to `/`-prefixed input — it
  cannot run arbitrary shell. `/goal` itself executes nothing; it sets an objective and
  a Stop hook. The goal text is Claude-drafted from a user-approved spec and
  user-approved before sending — there is no untrusted or external content entering
  the loop.
- **It increases oversight, not decreases it.** A pinned, checkable done-condition
  makes the run *more* legible: the user can see exactly what you committed to, and the
  Stop hook prevents the quiet "looks done, stopping early" failure mode.

The thing that would be unsafe is a *fuzzy* goal — an unfalsifiable condition the Stop
hook can never cleanly release. Step 1 exists precisely to prevent that. If you cannot
write a checkable done-condition, do not set a goal.

## After the goal is set

- The status line shows `◎ /goal active`; `/goal` also raises reasoning effort.
- Each subsequent turn, the goal is re-fed to you as an active directive — treat the
  done-condition as your standard and keep working toward it.
- The Stop hook **auto-clears** once the done-condition holds. Do not tell the user to
  run `/goal clear` after success — that command is only for abandoning a goal early.
- If you discover the goal was mis-scoped mid-run, surface it to the user and propose a
  revised goal; do not silently work to a different target than the one they approved.

## Phase transition — extension

Same channel-driven rationale as `/goal`: when the user is on Feishu / their
phone / any non-TUI surface, they cannot type the context-reset slash command
themselves. After a long autonomous phase completes, transitioning to the
next phase often benefits from a fresh context — the prior phase's
back-and-forth is no longer load-bearing, and re-feeding hundreds of turns
into the next phase wastes tokens and risks contaminating fresh thinking.

The `send-slash submit` helper from Step 3 above already accepts any slash
command (it gates only on the leading `/`), so no script change is needed
to fire the context-reset command. Just the workflow discipline below.

### When to use

All four conditions must hold:

1. The current phase's `/goal` done-condition is met (or no `/goal` was set
   for this phase).
2. The user has **explicitly approved the transition** in chat (a "yes" /
   "go ahead" / "reset and start phase N" message — never assume).
3. A handoff prompt for the next phase is ready (either you wrote one and
   sent it to the user, or the user is about to paste their own).
4. No in-flight subagents — `TaskList` shows nothing in_progress that
   depends on this session's context.

If any of these is false, do not reset. Send the user what's blocking and
wait.

### Sequence

1. **Final summary to user (Feishu/channel)**: one message that names what's
   ending and what's about to fire. Example:
   > "Phase 8c done — PR-A through PR-O all merged/pushed. About to reset
   > the TUI context to start Phase 9 fresh. Handoff prompt is at
   > `/tmp/phase-9-handoff-prompt.md` (also sent earlier in Feishu)."
2. **Send the handoff prompt file** via the channel BEFORE resetting — the
   user needs the prompt content to paste back as the first post-reset
   message. After the reset, you can no longer reference any local file
   path you wrote before; if the user doesn't have it cached in chat, the
   transition is lossy.
3. **Fire the reset** via send-slash submit, using the same vim-mode submit
   sequence the script provides. The argument is the built-in context-reset
   slash command (the one Claude Code documents under "clear the
   conversation").
4. **End your turn.** The reset may take a moment to land in the TUI. The
   next user message arrives in a fresh context — no prior conversation
   history, no prior `/goal`, no carried-over assumptions.

### Safety hard rules

These mirror the `/goal` safety properties — the context reset is more
destructive, so the rules are stricter:

- **NEVER reset without explicit user approval.** A chat message that reads
  "looks good, let's move on" is acceptable; ambiguous "ok" is not — ask
  explicitly.
- **NEVER reset while a subagent is running.** TaskList check first. If a
  subagent has a Monitor armed, check that too; the subagent's completion
  notification needs your session alive to be consumed.
- **NEVER reset while `/goal` is still active.** The Stop hook is bound to
  the `/goal` lifecycle; resetting mid-goal orphans the hook and the next
  phase inherits a phantom directive.
- **NEVER reset without sending the handoff prompt first.** After the
  reset, you can't.
- **NEVER reset as a way to skip an unfinished task.** If resetting feels
  like "let me start over to avoid finishing this", it's wrong — finish
  or escalate, don't wipe.

### What the reset does not preserve

This is the user's loss of context, not a hidden carry-over:

- Conversation history (gone).
- Loaded skills (must be re-`Skill:`'d in the new context).
- Active `/goal` (must be re-pinned if needed for the new phase).
- TaskList state (cleared — re-create the tasks you actually need).
- Subagent results that landed mid-phase but weren't yet integrated.

What DOES persist:

- Files on disk (git working tree, branches, anything in `/tmp` or the repo).
- Pushed commits (your work isn't lost — it's on the branch).
- Auto-memory (`MEMORY.md` and the linked memory files).
- The user's chat surface (Feishu still has every message that was sent).

The handoff prompt's job is to bridge the rest: point the next-phase agent
at the durable artifacts (memories, branch state, files on disk) so it can
reconstruct enough context to start.
