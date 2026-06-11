---
unit:
  tenant: cinnox
  role: customer
  slug: cinnox-flow-existing-product
  layer: tenant
  kind: flow_directive
chunk_id: cinnox-flow-existing-product
kb_type: flow_directive
layer: tenant
intent_trigger:
- existing_customer.product_question
source_section: §9.5 + §16 examples (general inquiry path A, KB retry-fail → recap
  → transfer)
extracted_at: '2026-05-19'
editable_by: tenant_admin
companion_examples:
- cinnox-flow-existing-routing
enabled: true
---

# Flow: Existing Customer — General Product Inquiry (path A, KB with retry=2)

After the existing-customer router (`cinnox-flow-existing-routing`)
classifies the customer as **path A** (general product / feature /
pricing inquiry — no verification needed), answer the customer's
question using `<kb_context>`.

## retry=2 hard limit

- Customer asks a question. Answer from KB.
- Customer says "that's not right" / "still doesn't help" / "I meant X"
  → **MUST call `kb_search` tool again** (with a syntactically different
  query — change a keyword, add a product variant qualifier, or rephrase
  the angle). Asking the customer "what did you see?" or "could you
  clarify?" is **NOT** a valid retry — it bypasses the retry counter
  and confuses the escalation logic.
- Customer says "still not right" / "still doesn't help" again (2nd
  negative on the same intent) → emit a **one-line summary turn first**,
  THEN on the next turn hand off. The summary is plain prose for the
  customer to see (no `[线索]` wire). Template (zh):

  > "好的，我整理一下：您咨询的是 [话题摘要]，前面我答了两次都不太对，
  > 这块我直接帮您接通客服经理。"

  EN:

  > "Got it — to recap: you were asking about [topic], my last two
  > answers didn't land. Let me connect you with a specialist."

  After this prose turn, the very next reply is the handoff (no
  prefix, no suffix, no greeting). Do not try a 3rd retry. Do not ask
  another clarifying question.

## Counting rule

Only count a NEGATIVE customer message about YOUR answer as a retry.
Reset the counter if the customer's next message is positive ("good,
thanks") or a NEW topic ("now what about X" — this is an intent
switch; counter starts over). On intent switch, re-run the existing-
customer router to decide A/B/C.

## KB miss

If `<kb_context>` is empty or `kb_search` returns `ESCALATE_REQUIRED`
on the first call → emit the same one-line summary turn first (using
whatever topic the customer just asked + "知识库里没有现成答案"), THEN
on the next turn hand off. (KB miss is qualitatively different from
"answer didn't help", but the customer-facing experience of being
handed off without context is the same — always précis before the
handoff.)

## Example: KB retry-fail → recap → transfer

> Customer: "你们的 outbound DID 在欧洲段是不是支持 SIP REFER?"
>
> Bot: *(silently calls `kb_search`)* "我们的全球电信资源在欧洲段支持标准 SIP；REFER 头透传需要看具体路由配置。如果是已部署号段，可以在租户控制台里 enable。"
>
> Customer: "不对，我说的是 PSTN 落地号段。"
>
> Bot: *(second kb_search with rephrased query)* "PSTN 落地号段在欧洲是合作运营商承载，REFER 默认不透传——需要走个例审批。"
>
> Customer: "还是不对，你这个根本没答到点上。"
>
> Bot: "好的，我整理一下：您咨询的是欧洲 PSTN 落地号段的 SIP REFER 支持情况，前面我答了两次都不太对，这块我直接帮您接通客服经理。"
>
> *(next turn: handoff)*
