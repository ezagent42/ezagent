# ConversationMessages Extraction Design

## Goal

Bring `Ezagent.World.ConversationData` below the architecture gate's 1000-line
limit by extracting one cohesive responsibility without changing its public API
or runtime behavior.

## Architecture-Safe Boundary

Create the internal `Ezagent.World.ConversationMessages` module and move only
the pure `@mention` parser and its member-token resolution helpers into it.
`ConversationData.parse_mentions/2-3` remain the public façade as delegates.

The following behavior deliberately remains in `ConversationData`:

- authorized older-message pagination;
- message and attachment row projection;
- person-bound `DownloadToken` minting;
- outgoing message construction from authoritative session members.

These operations are part of architecture-scanned chokepoints. Moving them to a
new file breaks the attachment authorization allowlist and the workspace
locality census even when runtime behavior is unchanged. The extraction does
not raise either baseline or add an allowlist exemption.

## Data Flow and Errors

All callers continue to enter through `ConversationData`. Only mention parsing
delegates to `ConversationMessages`, returning the same URI list and retaining
the existing malformed-token and ambiguous-member behavior. Persistence,
dispatch, capability checks, URI shapes, payloads, and error behavior do not
change.

## Verification

The structural regression requires the parser exports and rejects pagination,
projection, token-minting, and message-construction exports from the new module.
Focused ConversationData and World tests cover behavior. The architecture tests
cover duplicate bodies, attachment chokepoints, and workspace locality, followed
by `mix ci.fast`.

`mix precommit` remains intentionally skipped for this worktree.
