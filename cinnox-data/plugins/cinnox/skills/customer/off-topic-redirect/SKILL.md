---
name: off-topic-redirect
description: |
  Off-topic / non-CX customer-service request — redirect to m800.com/contact-us with 3-field lead capture.
applicable_roles: [customer]
safety_class: soft
editable_by: tenant_admin
depends_on: []
last_updated: 2026-05-21
version: 1
source: phase-e2 migration from plugins/cinnox/flow_chunks/cinnox-flow-other.md
channels: [text, voice]
---

# Flow: Other / Off-Topic Branch

Customer's request doesn't fit new / existing / partner. Examples:
recruiting inquiries ("你们有 RD 招聘吗?"), vendor pitches ("我们做 CRM
集成,想合作"), media inquiries, generic non-CX questions ("CINNOX 大概
多少员工?").

Direct them to the general contact page, **and** offer 3-field lead
capture in this channel as a fallback (same rationale as the partner
branch).

## Mandatory URL

**Your next reply MUST contain the literal URL
`https://www.m800.com/contact-us`.** Missing the URL means the
customer can't reach the right team. If you find yourself drafting
internal reasoning or meta-commentary instead of the customer-facing
message, STOP and output ONLY the customer-facing reply below
(URL + 3-field ask), nothing else.

## Single combined reply: link + 3-field ask

Emit ONE message containing BOTH the link and the 3-field ask:

> "您找的可能不是售前咨询。请到我们的联系页登记需求:
> https://www.m800.com/contact-us — 合适的同事会回您。
>
> 或者您也可以直接告诉我:姓名、公司名称、以及联系方式(邮箱或电话二选一),
> 我这边会安排合适的同事联系您。"
>
> EN: "This may be outside the customer-service scope. Please reach us
> at https://www.m800.com/contact-us — the right team will follow up.
>
> Or you can share your name, company, and one contact channel (email
> or phone) here, and I'll route it to the right team."

After emitting, **wait for the customer's reply**. Three branches:

## Branch 1 — Customer provides 3 fields

Confirm details (same confirmation pattern: "Let me confirm: Name: [X],
Company: [Y], Contact: [Z]. Is that correct?"). After confirmation,
record lead via SIDE channel with `type=other`. Then acknowledge:

> "好的,合适的同事会跟进。"

Do not force further routing. **Do NOT auto-emit the handoff token**
— let the customer drive the next turn.

## Branch 2 — Customer chooses the URL

Customer says "我去登记" / "got it" — acknowledge:

> "好的,合适的同事会在 1-2 个工作日内联系您。"
> EN: "Got it — the right team will be in touch within 1-2 business
> days."

No lead emit, no handoff-token emit.

## Branch 3 — Customer pivots to a real CX / product question

Re-classify. They may actually be `new_customer`; drop the "other"
classification and route accordingly (see `cinnox-flow-lead-new`).

## Example: customer provides fields → lead emit → no auto-transfer

> Customer: "你们公司在招前端工程师吗？"
>
> Bot: "您找的可能不是售前咨询。请到我们的联系页登记需求：https://www.m800.com/contact-us — 合适的同事会回您。
>
> 或者您也可以直接告诉我：姓名、公司名称、以及联系方式（邮箱或电话二选一），我这边会安排合适的同事联系您。"
>
> Customer: "张三 / Gamma / zhang@gamma.cn"
>
> Bot: "Let me confirm: Name: 张三, Company: Gamma, Contact: zhang@gamma.cn. Is that correct?"
>
> Customer: "对。"
>
> Bot: *(emits SIDE lead with type=other)* "好的，合适的同事会跟进。"
