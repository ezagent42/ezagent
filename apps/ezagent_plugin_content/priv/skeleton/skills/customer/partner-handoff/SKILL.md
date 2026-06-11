---
name: partner-handoff
description: |
  Channel partner / reseller / SI / distributor handoff to campaign.cinnox.com/partner-reseller with 3-field lead capture fallback.
applicable_roles: [customer]
safety_class: soft
editable_by: tenant_admin
depends_on: []
last_updated: 2026-05-21
version: 1
source: phase-e2 migration from plugins/cinnox/flow_chunks/cinnox-flow-partner.md
channels: [text, voice]
---

# Flow: Partner / Reseller / SI / Distributor Branch

Customer signals indicate they're a channel partner, not an end-customer
(keywords: "partner", "reseller", "system integrator", "SI",
"distributor"). CINNOX has a dedicated partner intake page that handles
SLA and commercial terms separately from sales. Direct them there,
**and** offer 3-field lead capture in this channel as a fallback (the
customer may not click the link; the in-channel lead ensures partner
ops can still reach back).

## Mandatory URL

**Your next reply MUST contain the literal URL
`https://campaign.cinnox.com/partner-reseller`.** Missing the URL
means the customer can't reach the partner team. If you find yourself
drafting internal reasoning or meta-commentary instead of the
customer-facing message, STOP and output ONLY the customer-facing
reply below (URL + 3-field ask), nothing else.

## Single combined reply: link + 3-field ask

Emit ONE message containing BOTH the link and the 3-field ask:

> "感谢您对 CINNOX 合作伙伴计划的关注。请到我们的合作伙伴登记页:
> https://campaign.cinnox.com/partner-reseller — 填写后会有专门同事联系您。
>
> 或者您也可以直接告诉我:姓名、公司名称、以及联系方式(邮箱或电话二选一),
> 我这边会同步给到合作伙伴团队。"
>
> EN: "Thanks for your interest in the CINNOX partner program. Please
> register here: https://campaign.cinnox.com/partner-reseller — the
> partner team will follow up.
>
> Or you can share your name, company, and one contact channel (email
> or phone) here in chat — I'll forward it to the partner team."

After emitting, **wait for the customer's reply**. Three branches:

## Branch 1 — Customer provides 3 fields

Confirm details (same confirmation pattern as new-customer lead:
"Let me confirm: Name: [X], Company: [Y], Contact: [Z]. Is that
correct?"). After confirmation, record lead via SIDE channel with
`type=partner`. Then proceed to the post-confirmation routing
(demo / specific question / vague request handling per
`cinnox-flow-lead-new`). **Do NOT auto-emit the handoff token** —
escalation only when standard escalation triggers fire.

## Branch 2 — Customer chooses the URL

Customer says "我去填了" / "OK, I'll use the link" / "got it" — acknowledge:

> "好的,合作伙伴团队会在 1-2 个工作日内联系您。"
> EN: "Got it — the partner team will be in touch within 1-2 business
> days."

**Do NOT** emit a lead record (no fields captured). **Do NOT** emit
the handoff token. Wait for the customer's next message; treat it
per the type-classification flow (re-classify) or answer per KB if
it's a product question.

## Branch 3 — Customer ignores both options and pivots to a product / demo question

Answer per KB or enter the non-standard request flow
(`cinnox-flow-non-standard`) if it's a demo. Partner status is a
mental note; the in-channel lead ask can be offered once more if
appropriate, but never insisted on.

## Example: customer chooses URL (no in-channel fields, no transfer)

> Customer: "We're a reseller in SEA, interested in becoming a CINNOX partner."
>
> Bot: "Thanks for your interest in the CINNOX partner program. Please register here: https://campaign.cinnox.com/partner-reseller — the partner team will follow up.
>
> Or you can share your name, company, and one contact channel (email or phone) here in chat — I'll forward it to the partner team."
>
> Customer: "I'll use the link, thanks."
>
> Bot: "Got it — the partner team will be in touch within 1-2 business days."
>
> *(no lead emit, no handoff token; conversation ends naturally or the customer's next message is re-classified.)*
