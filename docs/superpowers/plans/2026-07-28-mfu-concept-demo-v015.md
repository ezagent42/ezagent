# MFU Concept Model, Infographics, and Demo v0.15 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a coherent MFU v0.15 concept model, three stakeholder-facing infographics, and a playable demo that clearly separates experience, capability, recognition, role qualification, and platform feature access.

**Architecture:** Keep the single-file playable prototype, but replace the overloaded growth-tree presentation with distinct views for experience, capability achievement, credentials, and available platform functions. Use one durable concept-model document as the vocabulary source, keep `skill-tree.md` focused on capability maps, and create a v0.15 GDD snapshot. Build all visuals from the existing MFU parchment-and-paper design system.

**Tech Stack:** Markdown, standalone HTML/CSS/JavaScript, inline SVG, existing MFU single-file prototype, Node.js syntax validation, headless-browser screenshots when available.

## Global Constraints

- `mfu-demo/doc/platform-concept-model.md` is the single source of truth for platform concepts and their relationships.
- `mfu-demo/doc/tree/skill-tree.md` remains the single source of truth for capability-map content and rules.
- GDD files are version snapshots and are never edited after their version is superseded.
- Experience counts activity; capability requires evaluated evidence.
- Reputation level, professional certification, role qualification, and endorsement are distinct concepts.
- Platform features are opened by explicit rules and are not capability-map nodes.
- Personal capability nodes represent achieved outcomes, not in-progress learning states.
- Schools may define different courses; courses map many-to-many to platform-standard capabilities.
- Student, Agent, and shared contributions must be distinguished in evidence.
- The candidate profile must not collapse OPC readiness into one total score.
- Preserve the existing MFU visual language: parchment background, cream paper cards, warm-brown borders, solid offset shadows, and school/incubator/association semantic colors.
- No new dependency or CSS framework.
- Do not commit or push without ruihua's explicit approval.

---

### Task 1: Register the MFU visual system as a Codex skill

**Files:**
- Modify: `.claude/skills/mfu-design-system/SKILL.md`
- Create: `.claude/skills/mfu-design-system/agents/openai.yaml`

**Interfaces:**
- Consumes: the existing 288-line MFU visual specification.
- Produces: a discoverable `mfu-design-system` skill with valid YAML frontmatter and Codex UI metadata.

- [ ] **Step 1:** Add frontmatter with the exact skill name and triggers for MFU demos, infographics, and stakeholder visuals.
- [ ] **Step 2:** Add a short workflow requiring visual-token reuse, real MFU content, responsive layout, reduced motion, and screenshot-based critique.
- [ ] **Step 3:** Generate `agents/openai.yaml` using the skill-creator generator.
- [ ] **Step 4:** Run `quick_validate.py` and expect `Skill is valid!`.

### Task 2: Write the platform concept-model living document

**Files:**
- Create: `mfu-demo/doc/platform-concept-model.md`

**Interfaces:**
- Consumes: approved conversation decisions, `skill-tree.md`, GDD v0.13/v0.14, and `happy-paths-v0.13.md`.
- Produces: canonical definitions and relationship rules used by the infographics, GDD, and demo copy.

- [ ] **Step 1:** Define the platform purpose and five stakeholder roles: student, school, teacher, incubator, and association.
- [ ] **Step 2:** Define ownership boundaries for person, company, Agent, and role-bearing organization.
- [ ] **Step 3:** Define experience, evidence, capability, reputation level, professional certification, role qualification, endorsement, membership, and platform feature.
- [ ] **Step 4:** Define the six minimum OPC core capabilities and the professional capability branches.
- [ ] **Step 5:** Define achieved-node semantics and the three observable standards: basic application, independent delivery, and complex-project delivery.
- [ ] **Step 6:** Define course-to-capability many-to-many mapping and state that credits/hours are evidence inputs, not proof of mastery.
- [ ] **Step 7:** Define contribution attribution (`student-led`, `agent-led`, `shared`) and the conditions under which work becomes personal evidence.
- [ ] **Step 8:** Define the candidate profile and the three loops: learning, operating, and selection.
- [ ] **Step 9:** Add a status ledger distinguishing approved rules, v0.15 demo simplifications, and future governance work.
- [ ] **Step 10:** Self-review for ambiguous uses of “认证”, “解锁”, “技能”, and “成长树”; replace them with the canonical vocabulary.

### Task 3: Refactor the capability-map living document and create GDD v0.15

**Files:**
- Modify: `mfu-demo/doc/tree/skill-tree.md`
- Create: `mfu-demo/doc/MFU-策划案-GDD-v0.15.md`

**Interfaces:**
- Consumes: `platform-concept-model.md`.
- Produces: a capability-map-specific living document and a dated v0.15 product snapshot.

- [ ] **Step 1:** Replace the obsolete three-system passages with links to the concept model and a concise capability-map boundary.
- [ ] **Step 2:** Reclassify current nodes as capability, platform feature, reputation level, professional certification, role qualification, endorsement, or experience.
- [ ] **Step 3:** Replace the fine-grained professional-node proposal with broad capability areas and branching achievement standards.
- [ ] **Step 4:** Mark N-07/N-11, N-08/N-09/N-10, P-00–P-04, and the current role roots for migration out of the capability map.
- [ ] **Step 5:** Preserve historical decisions and record the new decisions as a new dated revision rather than silently rewriting history.
- [ ] **Step 6:** Create GDD v0.15 using v0.14's “relationship to previous version” format and document the concept model, capability map, course mapping, evidence attribution, and feature-access layer.
- [ ] **Step 7:** Verify that v0.14 remains unchanged.

### Task 4: Build three stakeholder infographics

**Files:**
- Create: `mfu-demo/infographics/MFU-v0.15-机制信息图.html`
- Create after rendering: `mfu-demo/infographics/MFU-v0.15-01-学生成长路径.png`
- Create after rendering: `mfu-demo/infographics/MFU-v0.15-02-多校课程映射.png`
- Create after rendering: `mfu-demo/infographics/MFU-v0.15-03-孵化器筛选闭环.png`

**Interfaces:**
- Consumes: concept-model language and `mfu-design-system` tokens.
- Produces: three 16:9 printable/screenshot-ready boards whose component styles can be reused in the demo.

- [ ] **Step 1:** Build the shared parchment canvas, paper-card, tag, evidence-card, capability-node, badge, and access-rule styles.
- [ ] **Step 2:** Build infographic 1: course practice → evaluated evidence → achieved capability → OPC operating practice.
- [ ] **Step 3:** Build infographic 2: different school courses → mapping table → shared platform capability standard.
- [ ] **Step 4:** Build infographic 3: capability evidence + experience + reputation/certification → incubator discovery → validation challenge → human invitation.
- [ ] **Step 5:** Add print/screenshot mode so each board renders independently at a stable 16:9 ratio.
- [ ] **Step 6:** Open each board in a browser, capture screenshots, and inspect hierarchy, overflow, contrast, and text density.
- [ ] **Step 7:** Remove at least one non-essential decorative element during the final visual critique.

### Task 5: Implement the playable MFU v0.15 demo

**Files:**
- Create from v0.14: `mfu-demo/MFU-v0.15-可试玩原型.html`

**Interfaces:**
- Consumes: infographic components and the v0.15 concept model.
- Produces: a standalone playable HTML demo with clear experience, capability, credential, and platform-access surfaces.

- [ ] **Step 1:** Preserve the playable loop from v0.14 and update only the profile/ERP progression surfaces and related state.
- [ ] **Step 2:** Add explicit data structures for reputation levels, professional certifications, role qualifications, endorsements, and external credentials.
- [ ] **Step 3:** Add company and personal experience summaries using count-based progress bars.
- [ ] **Step 4:** Replace fine-grained personal nodes with an achieved-capability map showing the six OPC core areas plus professional branches.
- [ ] **Step 5:** Add evidence attribution labels for student-led, Agent-led, and shared work in representative records.
- [ ] **Step 6:** Add company and personal credential shelves with source and verification labels.
- [ ] **Step 7:** Add the minimal external-credential form and render submitted credentials immediately as “平台外”.
- [ ] **Step 8:** Add a platform-feature access panel showing opened and pending features with plain-language reasons.
- [ ] **Step 9:** Make reputation status, not a removed tree node, drive the ending eligibility check while keeping final incubator invitation a human decision.
- [ ] **Step 10:** Add an OPC candidate-profile view with capability evidence, experience, credentials, gaps, and a next validation challenge; do not add a total score.
- [ ] **Step 11:** Preserve all unrelated gameplay paths and existing state transitions.

### Task 6: Verify and return the work

**Files:**
- Create: `docs/together/2026-07-28/returns/ruihua-mfu-v015-concept-demo.md`

**Interfaces:**
- Consumes: all Task 1–5 artifacts.
- Produces: verification evidence and an explicit approval checkpoint before git mutation.

- [ ] **Step 1:** Extract every `<script>` block from the infographic and demo HTML and run `node --check`; expect exit code 0.
- [ ] **Step 2:** Search the new demo for removed certification tree nodes and obsolete fine-grained personal nodes; confirm they are not rendered as capability-map nodes.
- [ ] **Step 3:** Search all v0.15 docs for contradictory definitions of experience, capability, certification, and feature opening; reconcile any conflict.
- [ ] **Step 4:** Run `mix precommit` with a long timeout and record the actual terminal result; a timeout or killed run is not a pass.
- [ ] **Step 5:** Write the return with files changed, user-visible behavior, screenshots, verification commands/results, remaining simplifications, and no unsupported completion claims.
- [ ] **Step 6:** Stop and request ruihua's review plus explicit commit/push authorization.
