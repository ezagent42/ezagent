defmodule Ezagent.Kind.Ports.CapabilityPort do
  @moduledoc """
  §3.4 CapabilityPort — the actor framework's narrow capability-semantics
  surface, resolved via `Application.fetch_env!(:ezagent_actor, :capability)`.

  Owner (core spine): `Ezagent.Capability`. The capability crosses the
  boundary as OPAQUE data (`term()`) — the framework NEVER pattern-matches
  or constructs the struct (§3.4 opacity rule; the reverse gate enforces
  it). Only these semantics/policy functions are ported. The core adapter
  (`Ezagent.Kind.Adapters.CapabilityAdapter`) delegates 1:1. Moves with the
  framework to `apps/ezagent_actor`.
  """

  @doc """
  Workspace of a URI (`%URI{}` or binary): the `%URI{}` workspace scope, or
  `:any` for workspace-agnostic targets. Consults `WorkspaceRegistry` on the
  core side (§3.3.2) — NOT pure.
  """
  @callback workspace_of(uri :: term()) :: term()

  @doc """
  Does `cap` (opaque) authorize cross-workspace traffic for `caller`
  (`%URI{}` caller or the membership-based `:any` bypass)?
  """
  @callback cross_workspace?(cap :: term(), caller :: term()) :: boolean()

  @doc "Stable identity key of a cap (opaque) for Receipt payloads."
  @callback identity_key(cap :: term()) :: term()
end
