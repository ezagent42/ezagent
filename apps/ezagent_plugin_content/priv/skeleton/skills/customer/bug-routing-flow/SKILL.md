---
name: bug-routing-flow
description: |
  Existing customer path C bug / complaint — route by product type (CINNOX product vs telco upstream) then proceed to self-troubleshoot or .har export (separate skill).
applicable_roles: [customer]
safety_class: soft
editable_by: tenant_admin
depends_on: []
last_updated: 2026-05-21
version: 1
source: phase-e2 migration from plugins/cinnox/flow_chunks/cinnox-flow-existing-bug-telco.md
channels: [text, voice]
---

# Flow: Existing Customer — Global Telco / PSTN / DID Issue (path C → 9.7b)

After the existing-customer router (`cinnox-flow-existing-routing`)
classifies path C (bug/complaint) AND Step 1 verification is complete,
when the customer selects option 2 (Global Telco — DID can't dial
out, number-range routing, PSTN fault), apply this flow.

Telco / PSTN issues can't be self-served; jump straight to 6-field
summary (same field set as the billing path — see
`cinnox-flow-existing-billing`).

## Proactively offer a failover number BEFORE handoff

Business shouldn't stop while the engineer takes over:

> "在工程师接手前,如果是 PSTN 受影响业务的,我可以先帮您调一个备用号过来,
> 业务不停。需要吗?"

EN: "Before the engineer picks this up — if a PSTN-impacted line is
disrupting business, I can arrange a temporary failover number to
keep things running. Want that?"

## Recap-then-handoff

After 6-field summary is gathered AND the failover-number question
is resolved (yes / no / N/A), emit a one-line recap turn BEFORE the
handoff:

> "好的，我整理一下：[姓名 / 公司 / 联系方式]；故障类型：[PSTN / DID / 路由
> 等具体描述]；备用号需求：[已记 / 不需要]。我现在帮您接通工程师。"

EN:

> "Got it — to recap: [name / company / contact]; issue: [PSTN / DID /
> routing detail]; failover number: [yes-arranged / not needed].
> Connecting you to an engineer now."

Then hand off on the next turn. Handing off before this recap turn
is a protocol violation (same byte-pure contract as the billing path).
