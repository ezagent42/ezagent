---
name: customer-type-clarifier
description: |
  First-turn customer-type classification when signals are weak — weak-signal example list, clarifier wording, and confirmation phrase recognition for new vs existing customer.
applicable_roles: [customer]
safety_class: soft
editable_by: tenant_admin
depends_on: []
last_updated: 2026-05-21
version: 1
source: phase-e2.6 extracted from runtime/sandbox/cinnox/slots/customer.yaml classification section
channels: [text, voice]
---

# Flow: Weak-Signal Customer-Type Clarifier

## Overview

§5 of the customer soul classifies the first substantive message into
one of four types (new_customer / existing_customer / partner / other)
using **strong** signal tables that stay inline in the soul. When the
message lacks any strong signal — the customer hasn't declared
identity, hasn't named a use case, hasn't mentioned account context —
the classification is **weak** and you must NOT auto-route. Instead,
ask one soft clarifying question, then re-read signals on the next
turn.

Hard cap: **2** clarifier turns total (see `weak_max_turns` in the
slot YAML). After 2 turns of weak signals, transition to §6.6
(m800-contact URL) — no further clarifications.

This skill is conditional and only loads when §5's strong-signal
tables fail to classify the current message.

## Weak signals (examples)

These look classifiable but are actually ambiguous — they could
plausibly be either a new evaluator OR an existing comparator, with
no identity declaration:

- `"我们公司想了解 CINNOX 价格"` — company asking pricing; could be
  new evaluating OR existing comparing tiers. NOT enough to commit to
  new_customer.
- `"请问 CINNOX 怎么用"` — could be either.
- `"have a question about pricing"` / `"I want to know about your
  service"` — generic, no identity declared.
- `"你们 X 功能怎么样"` — feature inquiry without identity.
- `"我们最近有 X 需求"` — has need but no new/existing signal.

If the customer message matches one of the above shapes (or is
clearly analogous), treat as **weak** and use the clarifier wording
below — do NOT pick new_customer or existing_customer by guess.

## Clarifier wording

Match the customer's language. Use the soft framing — tentative
particles ("方便问下", "呢", "Are you already…") make the question
feel like a check-in rather than an interrogation.

**Chinese (zh):**

> "方便问下您是已经在使用 CINNOX 产品，还是第一次了解咨询呢？"

**English (en):**

> "Happy to help! Are you already using CINNOX, or is this your
> first time looking into us?"

Do NOT use harsh / categorizing variants such as:

- ❌ `"请问您是 CINNOX 现有客户，还是第一次了解我们？"` (too clinical)
- ❌ `"are you new or existing?"` (too blunt; reads as form-filling)

The clarifier is **one open question only** — do NOT bundle it with a
lead-collection ask or a product answer. Let the customer's response
reveal identity, then re-classify on the next turn.

## Confirmation phrases

When the customer's response (after the clarifier) contains any of
the following, treat as confirmation of **new_customer** — even if
they also asked a product question in the same message:

- `"we are new"`
- `"我们是新客户"`
- `"新的"`
- `"haven't used before"`
- `"first time"`
- `"no account"`
- `"no, not yet"`
- `"我们没用过"`
- `"刚了解"`

When the response contains any of the following, treat as
confirmation of **existing_customer**:

- `"we are existing"`
- `"I have an account"`
- `"we use CINNOX"`
- `"我们在用"`
- `"现有客户"`
- `"老客户"`

After confirmation, branch per §4 gate decision for the confirmed
type (new → §6 soft/hard; existing → §9 routing).

## Max-turns guidance

The clarifier loop has a **hard cap of 2 customer turns**
(`weak_max_turns: 2`). Counting rule: each customer message where
signals remain weak counts as one turn. Once 2 turns elapse without
a strong signal:

- Stop asking clarifiers.
- Route to §6.6 (the "other" branch — m800-contact URL).
- Do NOT continue probing, do NOT call `kb_search` for routing
  purposes, do NOT attempt a third clarifier reword.

Rationale: customers who can't articulate a CINNOX-related need
within 2 turns are typically off-topic; routing to the general
contact page beats forcing a lead-collection flow they didn't ask
for. (Added 2026-05-14 for Tier 3 TC-018 enforcement; preserved
verbatim in Phase E2.6 extraction.)
