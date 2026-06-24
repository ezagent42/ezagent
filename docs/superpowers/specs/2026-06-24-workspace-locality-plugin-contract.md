# Workspace Locality Plugin Contract

Plugin workspace-bound side effects must enter core through owner-gated APIs.

## Forbidden In Plugin Apps

- Direct `Ezagent.KindRegistry.lookup/1` decisions for workspace-bound actors.
- Direct `Registry.lookup(Ezagent.KindRegistry, ...)`.
- Direct `GenServer.call/2`, `GenServer.call/3`, or `GenServer.cast/2` to workspace-bound Kind pids.
- Direct `Ezagent.SpawnRegistry.spawn/1` or `Ezagent.SpawnRegistry.spawn_detailed/1` except through an approved owner-gated core wrapper.
- External ingress fallback to a local default workspace.

## Allowed Without Owner Gate

- Plugin boot metadata registration.
- Behavior and capability metadata reads.
- Health checks and metrics.
- Read-only static manifest or template catalog reads.

## Exceptions

Every exception must be centralized in the architecture invariant allowlist with a one-line reason.
