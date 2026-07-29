# MFU Student Goals and Actions Infographics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Repair infographic pages 3–7 and extend the MFU v0.15 explainer with one student-goal overview and seven student-action mechanism pages.

**Architecture:** Keep all 15 boards in the existing single-file HTML artifact. Reuse the MFU paper-card component language, and give every action page the same visual grammar: action → direct records → conditional changes → non-automatic outcomes.

**Tech Stack:** Semantic HTML, CSS Grid/Flexbox, inline SVG where needed, and dependency-free browser JavaScript.

## Global Constraints

- Use the terminology in `mfu-demo/doc/platform-concept-model.md`; the product term is “成长树”.
- The audience may have no prior knowledge of MFU; each page must be understandable independently.
- Do not imply that every student action automatically raises every growth measure.
- Use solid arrows for direct records, dashed arrows for quality-dependent changes, and a gate symbol for eligibility/access.
- Preserve 16:9 desktop fit and provide a readable narrow-screen layout.
- Do not create screenshots as deliverables.
- Do not commit or push without ruihua’s explicit approval.

---

### Task 1: Repair pages 3–7

**Files:**
- Modify: `mfu-demo/doc/infographics/MFU-v0.15-机制信息图.html`

- [ ] Align page markup with the existing MFU paper-card classes.
- [ ] Restore visible borders, fills, shadows, semantic colors, and summary strips.
- [ ] Check pages 3–7 at the target 16:9 size and narrow width.

### Task 2: Add the student-goal overview

**Files:**
- Modify: `mfu-demo/doc/infographics/MFU-v0.15-机制信息图.html`

- [ ] Add page 8 with four student goals.
- [ ] Add an enlarged demo-style “today” panel showing how MFU prompts the next action.
- [ ] Connect each goal to the product UI that makes it visible.

### Task 3: Add seven student-action pages

**Files:**
- Modify: `mfu-demo/doc/infographics/MFU-v0.15-机制信息图.html`

- [ ] Add pages 9–15 for tasks/work, routing, delivery, evaluation, reflection, social cooperation, and certification/opportunity applications.
- [ ] Use the same direct/conditional/gated legend on every action page.
- [ ] State at least one outcome that does not change automatically on each page.

### Task 4: Verify the complete artifact

**Files:**
- Verify: `mfu-demo/doc/infographics/MFU-v0.15-机制信息图.html`

- [ ] Confirm all 15 navigation buttons select the correct board.
- [ ] Extract all script blocks and run `node --check`.
- [ ] Scan for deprecated or conflicting terminology.
- [ ] Run `git diff --check`.
- [ ] Render-check target-size and narrow layouts for clipping and missing shapes.
