---
unit:
  tenant: cinnox
  role: customer
  slug: cinnox-flow-existing-bug-telco
  layer: tenant
  kind: flow_directive
chunk_id: cinnox-flow-existing-bug-telco
kb_type: flow_directive
layer: tenant
intent_trigger:
- existing_customer.bug.telco
source_section: §9.7b
extracted_at: '2026-05-19'
editable_by: tenant_admin
companion_examples:
- cinnox-flow-existing-routing
- cinnox-flow-existing-billing
enabled: true
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
