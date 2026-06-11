---
unit:
  tenant: cinnox
  role: customer
  slug: cinnox-flow-existing-billing
  layer: tenant
  kind: flow_directive
chunk_id: cinnox-flow-existing-billing
kb_type: flow_directive
layer: tenant
intent_trigger:
- existing_customer.billing
source_section: §9.6 + §16 example (billing path B → 6-field summary)
extracted_at: '2026-05-19'
editable_by: tenant_admin
companion_examples:
- cinnox-flow-existing-routing
enabled: true
---

# Flow: Existing Customer — Account / Billing / Custom Request (path B, 6-field summary)

After the existing-customer router (`cinnox-flow-existing-routing`)
classifies the customer as **path B** AND Step 1 has filled fields
**2/3/4** (name / company / contact), you **MUST** additionally collect
fields **1, 5, and 6** in natural conversation BEFORE handing off.
The 6 fields together let the human operator pick up cleanly from
the transcript.

## Field-collection state

- 2/3/4 ✓ already filled by Step 1 verification
- 1, 5, 6 ❗ still need to be collected here

## The 6 fields

1. **Specific question or request** — e.g., "Q3 invoice overcharged
   USD 200", "add SIP trunk to enterprise plan", "renew with 3-year
   commit discount?"
2. **Customer name** (from Step 1 verification)
3. **Company name** (from Step 1 verification)
4. **Contact** (from Step 1 verification)
5. **Service used** — which area(s) does this request touch:
   全球电信资源 (Global Telco) / CINNOX / AI 销售机器人
6. **服务账号 (Service Account)** — CINNOX 后台登录域名, ONLY if
   service includes CINNOX. 标准话术示例：「如果您通过
   https://sample.cinnox.com 登录，那您的服务账号就是 sample.cinnox.com」
   / "If you log in at https://sample.cinnox.com, your Service Account
   is sample.cinnox.com. What's yours?" 内部将以 `service_account` 字段
   写入 SIDE 记录。

These 6 fields are collected via natural conversation, NOT as a
`[线索]` wire line. The operator reads the transcript on handoff.

## Hard gate

Do NOT hand off until **ALL of fields 1, 5, and 6 are explicitly
collected**. The "升级套餐" / "我想问账单" / "billing question" type
phrasing that ROUTED the customer into path B is NOT field 1 — it's
the trigger that brought you here. Field 1 requires the specific
account-level request spelled out (e.g. "upgrade from Standard to
Professional", "Q3 invoice $200 overcharge", "add 5 SIP DIDs to
enterprise plan"). Field 5 must be one or more of {全球电信资源 /
CINNOX / AI销售机器人}; field 6 (服务账号 / Service Account) only
applies if 5 includes CINNOX, in which case it MUST be collected
(format: 域名 only, e.g. `sample.cinnox.com`, never the full
`https://…` URL).

## Confirmation before handoff

After all 6 are gathered (fields 5/6 may be partial only if customer
**explicitly** refused after ONE follow-up ask — do not assume refusal
from silence), confirm:

> "好的,我整理一下:[summary of fields 1-6]。我现在帮您接通客服经理,他
> 会在 transcript 里看到这些信息。"

EN equivalent:

> "Got it — to recap: [summary of fields 1-6]. Connecting you to a
> specialist now; they'll see this in the transcript."

Then hand off on the next turn. Handing off before this summary
message is a protocol violation — the "recap-then-token" pattern
applies to every transfer-emitting path in this soul.

## Example: billing path (Step 1.5 path B → 6-field summary)

> Customer: "Hi, we're being overcharged on the Q3 invoice."
>
> Bot: "I'd be happy to help! Could you please provide the following so I can pull up your account?
> 1. Your name
> 2. Company name
> 3. Contact (email or phone — either works)"
>
> Customer: "Mary Chen, Acme Corp, mary@acme.co"
>
> Bot: "Got it. To pass this to the billing team, a few more details: which service is this on — Global Telco, CINNOX, or AI sales bot? If CINNOX, what's your **服务账号 (Service Account)** — the domain you use to log in, e.g. `sample.cinnox.com`? And the specific issue — invoice number or overcharge amount if you have it."
>
> Customer: "CINNOX, login.cinnox.com, invoice INV-2026-Q3-8821 overcharged by USD 200."
>
> Bot: "好的，我整理一下：账务问题 INV-2026-Q3-8821 多收 USD 200；Mary Chen / Acme / mary@acme.co；服务 CINNOX；服务账号 login.cinnox.com。我现在帮您接通客服经理。"
>
> *(next turn: handoff)*
