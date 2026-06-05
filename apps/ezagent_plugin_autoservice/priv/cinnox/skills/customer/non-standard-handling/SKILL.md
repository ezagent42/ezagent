---
name: non-standard-handling
description: |
  Demo / quote / non-standard request after lead is saved — ask 3 discovery questions (scenario / scale / target) then hand off.
applicable_roles: [customer]
safety_class: soft
editable_by: tenant_admin
depends_on: []
last_updated: 2026-05-21
version: 1
source: phase-e2 migration from plugins/cinnox/flow_chunks/cinnox-flow-non-standard.md
channels: [text, voice]
---

# Flow: Non-Standard Request (Demo / Quote / Other) — after lead saved

When a new customer asks for a **demo / custom quote / other
non-standard need** (anything not answerable from KB Q&A), run an
**abbreviated Discovery** before escalating. The human team needs
context to be useful; transferring blind wastes time on both sides.

Prerequisite: lead is already collected and confirmed
(see `cinnox-flow-lead-new` HARD branch).

## Abbreviated Discovery — 2-3 short questions

Ask 2-3 short questions (one per turn, each builds on the previous):

1. **Scenario / use case**:
   > "您主要想用在哪个场景? 例如售前咨询、客服、电销?"
   > EN: "What are you trying to solve — sales ops, customer support, telesales?"

2. **Scale**:
   > "目前大概多少坐席,主要用什么渠道?"
   > EN: "Roughly how many agents/users, and what channels are you handling today?"

3. **Target / focus** (only if not yet clear from earlier turns):
   > "Demo 里有特别想看的功能吗? 或者您想改善的指标?"
   > EN: "Anything specific you'd like to see in the demo, or a metric
   > you want to improve?"

## After 2-3 turns — acknowledge + escalate

> "好的,我整理一下您的需求,客服经理会带着这些背景和您联系。"
> EN: "Got it — I'll summarize your needs and our sales team will follow
> up with this context."

Then emit the handoff token. The human handles scheduling / quoting /
next steps from there.

## Rules

- Do NOT schedule date/time yourself — leave that to the human.
- Do NOT pitch features beyond what the customer mentions — Discovery
  is for understanding, not selling.
- Do NOT proceed to KB Q&A for a non-standard request — the answer
  isn't in KB.
- Total turns from non-standard intent → handoff: ~3-4 (lead already
  collected → 2-3 Discovery turns → escalate).
- If customer pushes back ("just connect me, I don't want to answer
  questions"), proceed to the handoff immediately after that turn.
- The bot does discovery; the human handles scheduling.
