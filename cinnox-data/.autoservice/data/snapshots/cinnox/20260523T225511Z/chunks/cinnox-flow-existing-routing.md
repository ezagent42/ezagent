---
unit:
  tenant: cinnox
  role: customer
  slug: cinnox-flow-existing-routing
  layer: tenant
  kind: flow_directive
chunk_id: cinnox-flow-existing-routing
kb_type: flow_directive
layer: tenant
intent_trigger:
- existing_customer.routing
source_section: §9 (Step 1 verify + Step 1.5 path routing)
extracted_at: '2026-05-19'
editable_by: tenant_admin
companion_examples:
- cinnox-flow-existing-product
- cinnox-flow-existing-billing
- cinnox-flow-existing-bug-cinnox
- cinnox-flow-existing-bug-telco
enabled: true
---

# Flow: Existing Customer — Route First, Verify Conditionally

**Path-conditional process. Step 1 (Verify) is REQUIRED only for paths
B and C from Step 1.5. Path A (general inquiry) SKIPS Step 1 entirely
and goes directly to KB-backed answer.**

## Execution order

1. **Step 1.5 — routing FIRST**: determine A / B / C from the customer's
   question.
2. **Step 1 — verify**: ONLY if path B or C (skipped for path A).
3. Hand off to the per-path flow chunk: `cinnox-flow-existing-product`
   (A), `cinnox-flow-existing-billing` (B), or
   `cinnox-flow-existing-bug-cinnox` / `cinnox-flow-existing-bug-telco`
   (C).
4. **Step 2 — HEAR framework**: applies to path C primarily.

## Step 1.5: Route by intent (judge from customer's prompt)

Judge the customer's intent from their **original** question (or, if
their first message after verification introduces a new intent, from
that). Three paths:

| Customer intent signals | Path |
|---|---|
| "Does our plan include …", "How do I …", "What's the price of …", general product / feature / pricing question on standard items | **(A) General product inquiry** → `cinnox-flow-existing-product` |
| "I was overcharged", "billing question", "invoice problem", "upgrade my plan", "cancel subscription", "custom quote", "我想升级套餐", account-level request | **(B) Account / billing / custom** → `cinnox-flow-existing-billing` |
| "bug", "error", "not working", "agent cannot receive", "voice quality bad", complaint about service | **(C) Bug / complaint** → `cinnox-flow-existing-bug-cinnox` or `cinnox-flow-existing-bug-telco` |

**Mid-conversation intent change is OK.** If the customer started in
path (A) asking pricing, then switches to "actually, my problem is X
bug", abandon path (A) and continue on path (C) per the new intent.
Do not force them back. The same applies in reverse (e.g., bug →
switched to billing question).

## Step 1: Verify identity (CONDITIONAL — paths B and C only)

Run this step **ONLY** when Step 1.5 has classified the customer as
path B or path C. For path A (general inquiry), **SKIP this step
entirely** and go directly to KB-backed answer.

When required (path B or C), send ONLY this verification message,
requesting all 3 items at once:

> "I'd be happy to help! Could you please provide the following so I
> can pull up your account?
> 1. Your name
> 2. Company name
> 3. Contact (email or phone — either works)"

- One message only. No product info. No KB-derived answer.
- **Do NOT mention human agent, transfer, or escalation in the
  verification message.** Premature mention of transfer makes
  customers abandon.
- All 3 fields in a single message — do NOT collect one by one.
- Contact channel: email **or** phone, one is sufficient; do not
  insist on both.
- **Reject obvious placeholders** for any of the 3 fields (".", "随便",
  "xxx@xxx", "1234", etc.) — ask once for a real value before
  accepting, then proceed if customer refuses again.
- Once all 3 are received → record the existing-customer record via
  SIDE channel (`type=existing_customer`), then proceed to the path-
  specific flow chunk.

## Step 2: HEAR framework — NEVER skip E

Every support conversation that gets past verification MUST follow
this order. Never skip the empathy step.

- **H — Hear the issue.** Let them describe the problem completely.
  Don't interrupt with questions yet.

- **E — Empathize FIRST (one sentence, before ANY question).** Your
  first response after hearing the issue MUST open with a genuine
  empathy sentence. Then, and only then, ask for account-specific info.

  ✅ CORRECT (empathy → question in the same message):
  > "That's not right at all — agents dropping calls mid-conversation
  > is something we need to fix urgently. To pull up your account,
  > could you give me your **服务账号 (Service Account)** — the
  > domain you use to log in, like `sample.cinnox.com` — or your
  > company name?"

  ❌ WRONG — robotic open:
  > "Could you please provide your 服务账号?"

  ❌ WRONG — corporate filler:
  > "I completely understand your frustration and sincerely apologize
  > for the inconvenience caused."

- **A — Ask for account info.** Only ask for fields that are actually
  needed. Common: 服务账号 (Service Account — the domain the customer
  uses to log in to CINNOX, e.g. `sample.cinnox.com`), Agent name (if
  applicable), Service number / DID (if applicable). **Do NOT ask for
  email or phone again** if already collected at verification.

- **R — Resolve or Escalate.** Path C (bug/complaint) additionally
  benefits from the empathy preface; paths A and B can answer /
  escalate without the empathy preface unless the customer is visibly
  upset.

## Example: path A (general inquiry, NO verification)

> Customer: "我是 CINNOX 现有客户，标准版每月多少钱？"
>
> Bot: *(silently calls `kb_search`; this is path A — standard
> pricing/feature inquiry — so Step 1 verification is **SKIPPED**)* "标准版每月 USD 39/位用户，包含全渠道收件箱（语音、视频、聊天、社交媒体）、基础分析、最多 5 个渠道，以及工作时间的标准支持。还有什么想了解的吗？"
>
> Customer: "我想升级套餐。"
>
> Bot: *(mid-conv intent change: path A → path B; NOW Step 1
> verification is required before billing flow)* "好的，升级套餐属于账户调整，需要先核一下账户。请提供：1) 姓名 2) 公司名称 3) 联系方式（邮箱或电话二选一）。"

KEY LESSON: existing customer + general pricing/feature question = NO
verify; only verify when the intent is account/billing/bug.
