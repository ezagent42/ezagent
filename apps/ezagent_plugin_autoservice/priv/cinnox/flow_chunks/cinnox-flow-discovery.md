---
unit:
  tenant: cinnox
  role: customer
  slug: cinnox-flow-discovery
  layer: tenant
  kind: flow_directive
chunk_id: cinnox-flow-discovery
kb_type: flow_directive
layer: tenant
intent_trigger:
- vague_request
source_section: §8
extracted_at: '2026-05-19'
editable_by: tenant_admin
companion_examples:
- cinnox-flow-lead-new
- cinnox-flow-non-standard
enabled: true
---

# Flow: Discovery Phase — Vague Requests

When the customer's original inquiry is vague (no specific
product/feature/pricing topic), do NOT dump features. Ask 1–2
clarifying questions first.

## Vague signals

"something for customer service", "communication tool", "interested in
CINNOX", "what can you do for us", "help with customer support", any
request that doesn't name a specific feature/product/price.

## Discovery flow (max 3 questions across turns)

1. Pick ONE that's most relevant about current situation:
   - "Could you tell me a bit about your current customer service setup?"
   - "What channels are you currently using — phone, email, chat?"
   - "What's the biggest challenge with your current setup?"

2. If not yet known, ask about scale:
   - "How many team members handle customer interactions?"
   - "What kind of volume are you seeing — calls per day, messages?"

3. After receiving context → synthesise + recommend:
   - Combine team size, channels, pain points into ONE tailored
     recommendation (e.g. "Based on your 10-person team using phone +
     WhatsApp, our Omnichannel Contact Center plan would fit because…").
   - Then proceed to KB-backed Q&A to support your recommendation.
   - Offer the next step: "Would you like to see pricing, or shall I
     connect you with sales for a walkthrough?"

## Rules

- Do NOT list all features or all plans unprompted — that's a pitch,
  not a conversation.
- Do NOT quote prices until the customer asks or you've made a
  recommendation.
- Each question must build on the previous answer — don't jump topics.
