# Socialware Data Split and Deployment Boundary

Date: 2026-07-01
Trigger: #1106 AutoService seed review and #1110 kanban split review

## Principle

A socialware app is not a seed script and not a monolithic integration branch.

It has three separable carriers:

1. **Definition data**: product-specific content and configuration.
2. **Runtime substrate**: generic mechanisms that can run many socialware apps.
3. **Installer/deployment flow**: a repeatable way to install definitions into a
   workspace, start the right runtime pieces, and verify the app.

Seeds are allowed as installers or E2E harnesses. They are not the product
definition.

## Correct Carrier

| Artifact | Long-term carrier | Installer responsibility |
|---|---|---|
| Persona / soul | AgentTemplate, soul markdown, ConfigObject, socialware package data | Import or select it |
| KB corpus / examples | resource fixture, package data, uploaded resource | Ingest it |
| Session shape | SessionTemplate / socialware definition | Instantiate it |
| Routing policy | SessionTemplate / routing config data | Install through public APIs |
| Role recipes | plugin/default-pack definition data | Register or select recipe |
| Capability requests | role recipe / package manifest / supported grant policy | Grant through CapBAC chokepoint |
| UI surface declaration | plugin surface provider / package metadata | Enable or link it |
| External integrations | plugin runtime + package config | Provision credentials/config without hardcoding |
| Runtime binding | supported product/API path | Call the supported path, not private stitching |

## AutoService Example

#1106 proved the Tier-1 chain can run, but `scripts/autoservice_tier1_seed.exs`
currently carries support persona, KB corpus, and session/orchestrator wiring as
Elixir code. That is acceptable as a harness and regression proof. It is not the
product shape.

Target:

1. Support persona becomes definition data.
2. KB corpus becomes resource fixture/package data.
3. Session and routing become SessionTemplate/socialware definition.
4. Seed becomes an installer/verifier for the package.
5. Any need to call `McpRegistry.register/2`, `SessionManager.ensure_started/1`,
   or hand-write working-copy bindings is treated as evidence that a supported
   install/runtime path is missing.

## Kanban Example

Kanban should follow the same boundary:

1. Board workflow stages and PM/dev roles are package/recipe data, not a
   hardcoded integration branch.
2. Generic role-agent materialization belongs in substrate.
3. Kanban behavior, GitHub gateway, and kanban UI belong in plugin/runtime.
4. Demo/evidence docs are not merge units for runtime substrate.
5. Install/deploy should create the session/team/board from package data and
   then run E2E verification.

## PR Rule

When a PR introduces or modifies a socialware app, the PR body must state:

1. What is definition data.
2. What is runtime substrate.
3. What is install/deploy flow.
4. What is fixture/demo-only.
5. How AutoService or kanban would use the same boundary, if the PR only touches
   one of them.

If the answer is "the seed or integration branch is the product," stop and
split the design first.
