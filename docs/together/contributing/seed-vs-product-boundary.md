# Seed vs Product Boundary

Date: 2026-07-01
Trigger: #1106 AutoService Tier-1 seed review

## Principle

A seed is an installer or verifier. It is not the product feature.

Seed code may assemble an environment, install definitions, ingest fixture data,
grant capabilities through the normal chokepoints, and start supported runtime
paths. It must not become the long-term home of business persona, business
corpus, product routing policy, or private runtime wiring.

## Correct Carrier

| Artifact | Correct long-term carrier | Seed responsibility |
|---|---|---|
| Agent persona / soul | AgentTemplate, soul markdown, socialware config, or versioned definition data | Import or select it |
| KB corpus | resource, fixture file, ConfigObject payload, or product package data | Ingest it |
| Session shape | SessionTemplate / socialware definition | Instantiate it |
| Routing policy | SessionTemplate / routing config data | Install it through public APIs |
| Capability policy | role recipe / ConfigObject / supported grant path | Grant through CapBAC chokepoint |
| Runtime binding | supported product/API path | Call the supported path, not private stitching |

## What #1106 Proved

#1106 was acceptable as an E2E proof because it did not put AutoService business
rules into core/domain dispatch, CapBAC, Kind, or Resolver logic. It proved that
the current architecture can run the AutoService Tier-1 chain.

The uncomfortable part is that `scripts/autoservice_tier1_seed.exs` now carries
AutoService persona, KB corpus, and orchestration/session wiring as Elixir code.
That is fine as a short-lived harness. It is not the product shape.

## Target Shape

AutoService should become a data/package composition:

1. Support persona lives as definition data, not a string constant in a seed.
2. KB corpus lives as resource/fixture/package data, not a module attribute.
3. Session template and routing live in a template/socialware definition.
4. The seed only installs that package into a workspace.
5. If the seed must call `McpRegistry.register/2`,
   `SessionManager.ensure_started/1`, or hand-write an orchestrator working copy,
   that is a sign the product/API path is missing or too implicit.

## Handoff Rule

When a PR introduces a seed for a product scenario, the PR body must state:

1. Which parts are temporary harness data.
2. Which parts are intended product definition data.
3. Which supported product/API path the seed is exercising.
4. The follow-up plan for moving business content out of seed code.

If the answer is "the seed is the feature," stop and redesign.
