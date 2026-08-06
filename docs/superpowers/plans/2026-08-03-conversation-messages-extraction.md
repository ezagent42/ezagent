# ConversationMessages Extraction Implementation Plan

**Goal:** Extract the pure mention parser from `ConversationData` so the file is
below 1000 lines without changing its public API or architecture chokepoints.

**Architecture:** `ConversationMessages` owns only `parse_mentions/2-3` and its
pure helpers. Authorized reads, message projection, attachment token minting,
and construction stay in `ConversationData`.

## Constraints

- Preserve every existing `ConversationData` public function and return shape.
- Do not change persistence, dispatch, capabilities, URI shapes, or payloads.
- Do not update architecture baselines or allowlists.
- Do not run `mix precommit`; run focused tests and `mix ci.fast`.

## Tasks

- [x] Add a RED structural test requiring the parser-only module boundary.
- [x] Extract `parse_mentions/2-3` and its private helpers.
- [x] Keep pagination, projection, token minting, and construction in the
  architecture-approved `ConversationData` chokepoint.
- [x] Format the touched Elixir files and run `git diff --check`.
- [x] Run ConversationData tests: 33 tests, 0 failures.
- [x] Run directly relevant World tests: 3 tests, 0 failures.
- [x] Run the affected architecture gates: 8 tests, 0 failures.
- [x] Run `mix ci.fast`: exit 0.
