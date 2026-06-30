# Spec: Agent Console IA refresh (overview-first, roster naming, workspace/admin split)

> **Date:** 2026-07-01
> **Author:** Claude + user
> **Status:** brainstorm-approved
> **Scope:** information architecture, naming, navigation, and prototype direction for the current Agent Console review
> **Out of scope:** backend contract changes, permission model changes, session lifecycle semantics, kanban plugin product design

## 0. Why this spec exists

The current Agent Console review started as a completeness audit, but PM dogfood exposed a second class of problems: **the UI often fails to explain the real usage path even when underlying capabilities already exist**.

This spec records the agreed IA direction so the prototype, the final return doc, and future product discussions all reference the same decisions.

The problem is not only "which pages exist". The deeper problem is:

- the current shell is too close to internal object taxonomy in some places
- too many paths rely on users already understanding the model
- some powerful entry points exist, but are not surfaced as first-class visible navigation
- the current create/detail flow exposes low-level fields too early

This spec therefore focuses on **user journey first**, while still respecting the real system structure.

## 1. Design goals

The refreshed Agent Console should:

1. **Explain the first step.**
   A first-time user should be able to land on the console and understand what they can do next.

2. **Preserve expert shortcuts.**
   A familiar operator should still be able to jump directly to list/detail/config pages without going through a wizard-like homepage every time.

3. **Reflect the real system, but in product language.**
   The UI should not invent fake concepts, but it should translate internal terms into names users can understand.

4. **Separate workflow surfaces from system-config surfaces.**
   This follows the already-landed shell perspective split in the codebase: `workspace` perspective vs `admin` perspective.

5. **Push deep configuration down.**
   Creation and detail pages should start with business-meaningful information, then reveal advanced runtime/config fields later.

## 2. Core IA decision

### 2.1 Default landing model

The default landing page is **Overview**, not a raw object list.

Overview is responsible for:

- showing what currently exists
- showing what needs attention
- giving clear next-step actions
- linking directly into the real surfaces

Overview does **not** replace the real console navigation. It is a guided landing page layered on top of it.

### 2.2 Persistent left navigation

The left sidebar remains persistent and maps to the real product structure rather than hiding everything behind Overview.

The agreed direction is:

- **Overview**
- **Sessions**
- **Roster**
- **Workspaces**
- **Plugins**
- **Profile**
- **Admin**

This preserves the value of direct-entry navigation while making the first screen more approachable.

## 3. Naming decisions

### 3.1 Why not keep `Identities`

`Identities` is structurally accurate, but too close to internal taxonomy. It does not clearly answer the product question:

> "Who or what participates in work inside this workspace?"

For product-facing IA, this area is really about the set of participants available to the workspace: people, agents, and their access.

### 3.2 Chosen name: `Roster`

The agreed replacement is **Roster**.

Reasons:

- it reads like a workspace participant roster
- it can include both people and agents
- it naturally supports access/capability drill-down without sounding too technical
- it fits the "responsibility / who participates" mental model better than `Identities`

### 3.3 Sub-navigation under Roster

`Roster` becomes a first-class section with visible secondary tabs:

- **All**
- **People**
- **Agents**
- **Access**
- **New Agent**

The previous `Capabilities` label is translated to **Access** in the product surface. The underlying concept is still capability/capbac, but the product framing should answer the user question:

> "Who can do what?"

instead of exposing the internal noun too early.

## 4. Workspace structure

### 4.1 Why Workspace needs to be deeper

The previous prototype treated Workspaces as a single coarse page. That is insufficient.

The `workspace` concept in ezagent is not just a list object. It is the main scope container for:

- people and agents
- session templates / recipes / socialware definitions
- routing and rules
- plugin/app configuration
- workspace-level health and activity

So the Workspace surface should be deeper and more structured.

### 4.2 Chosen Workspace sub-structure

For a workspace detail surface, the agreed direction is:

- **Overview**
- **Roster**
- **Sessions**
- **Recipes & Templates**
- **Rules**
- **Apps**
- **Health**

This is intentionally a product translation of the underlying axes:

- the **workspace/admin perspective split** determines the outer shell separation
- the **recipe/responsibility concepts** help drive the inner grouping:
  - `Roster` corresponds to who participates / responsibility slots
  - `Recipes & Templates` corresponds to reusable definition/config content

We do **not** expose `recipe` or `responsibility` as raw left-nav terms, because they are better as model semantics than as top-level product labels.

## 5. Two-perspective shell

The codebase already documents a two-perspective shell:

- `workspace` perspective for workflow surfaces
- `admin` perspective for system-config surfaces

This spec adopts that directly for the UI story.

### 5.1 Workspace perspective

This includes:

- Overview
- Sessions
- Roster
- Plugins
- Profile

and the day-to-day workspace-facing work.

### 5.2 Admin perspective

This includes:

- admin dashboard
- observability
- registry
- snapshots
- templates
- capabilities / authz audit
- settings
- routing
- workspace-level configuration surfaces that behave like system config

The UI implication is:

- `Admin` should remain a first-class entry
- `Admin` should have **visible secondary navigation**
- admin subpages should not be discoverable only through deep links, URL knowledge, or command palette

## 6. Create and detail flow principles

### 6.1 Creation flow

The console should not behave like a naked low-level object constructor.

Creation should:

- start with the user's intent / use case
- optionally attach the new agent to a real working context
- keep advanced runtime fields below the fold

For example, a PM creating a Claude helper should not hit `project_cwd` as the first required concept.

### 6.2 Detail flow

Detail pages should default to:

- current state
- connected sessions / usage context
- recommended next actions

Only after that should they reveal:

- flavor
- runtime mode
- cwd
- model/provider
- MCP/config paths

This keeps the system honest without making every detail page feel like an admin-only backend screen.

## 7. What this means for the prototype

The prototype should reflect the following changes:

1. Keep **Overview** as the default guided landing page.
2. Keep the persistent left sidebar.
3. Rename **Identities** to **Roster**.
4. Rename **Capabilities** to **Access** in the product-facing surface.
5. Add visible secondary navigation for `Roster`.
6. Deepen `Workspace` into a real multi-section detail experience.
7. Keep `Admin` as a first-class entry with visible secondary navigation.
8. Preserve direct-entry paths for experienced users.

## 8. Non-goals

This spec does **not** decide:

- any change to CapBAC semantics
- any cross-workspace authority change
- session archive/delete implementation
- plugin-specific product flows outside Agent Console scope
- whether `Roster` should become a code-level rename

This is a **product IA and naming spec**, not a backend model rewrite.

## 9. Open follow-up questions

These do not block the prototype direction, but should be reviewed in the next design pass:

1. Should the left nav visually group items into `Workspace` vs `Admin`, or keep one flat list with stronger active-state cues?
2. Should `Workspaces` stay plural in the top nav while `Roster` and `Sessions` are workspace-local, or should a future shell become explicitly current-workspace scoped?
3. Should `Recipes & Templates` later split into two separate pages once the underlying product semantics are clearer to users?
4. Should `Access` stay nested under `Roster`, or eventually become a dedicated cross-surface governance page for advanced operators?

## 10. Accepted decision summary

The agreed direction is:

- **Overview first**
- **persistent left navigation**
- **`Roster` replaces `Identities`**
- **`Access` replaces product-facing `Capabilities`**
- **Workspace detail becomes deeper and multi-section**
- **outer shell follows the landed `workspace/admin` perspective split**

This is the design basis for the refreshed prototype and for the final "design issues" section in the Agent Console completeness return.
