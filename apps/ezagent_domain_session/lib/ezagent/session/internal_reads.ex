defmodule Ezagent.Session.InternalReads do
  @moduledoc """
  The INTERNAL-read gateway (read-plane design §3.4 —
  `docs/superpowers/specs/2026-07-19-read-plane-authz-chokepoint-design.md`).

  Principal-facing reads authorize a caller at a read chokepoint
  (`Ezagent.Socialware.SessionReads`, `Ezagent.Workspace.WorkspaceReads`,
  `Ezagent.Identity.OperatorReads`, …). Framework-internal flows — delivery
  replay, reconcile, GC, boot, snapshot-rehydrate — have NO principal to
  authorize; they read the raw stores through THIS gateway instead of
  touching them directly. It is the SINGLE module such no-principal reads
  go through — never a blanket "this whole caller module is exempt".

  ## Two-sided boundary

  Both sides are enforced by the module-keyed arch gate
  `apps/ezagent_core/test/architecture/internal_reads_gateway_boundary_test.exs`:

    * **Outbound** — the gated raw-store read functions
      (`MessageStore` windowed reads, the workspace enumeration primitives)
      are callable only from {the read chokepoints, this gateway}. Any other
      framework-tier module calling them → CI red.
    * **Inbound** — this gateway may be CALLED only from the enumerated
      framework-internal caller tier (today: session delivery replay +
      session reconcile). A principal-facing module (LiveView loader,
      controller, chokepoint caller) calling `InternalReads` → CI red. The
      inbound side is what stops the gateway becoming a laundering path
      around `SessionReads`.

  ## Keep it NARROW

  Every function here is a thin, policy-free delegation to ONE raw-store
  read — no authz (there is no caller), no row-policy, no shaping. Adding a
  function means adding laundering surface, so the gate ratchets the public
  surface to exactly the enumerated set; extend it only for a genuinely
  framework-internal, no-principal read.
  """

  alias Ezagent.MessageStore

  @doc """
  Messages in `session_uri` strictly after `last_seen_at`, ascending — the
  at-most-once rejoin REPLAY read used by
  `Ezagent.ActionSet.Session.Delivery.replay_messages_since/3` when a member
  rejoins. Delegates to `MessageStore.in_session_since/2` (unchanged
  semantics: routing-join, workspace-pinned, `@replay_cap`-bounded).
  """
  @spec messages_since(URI.t(), DateTime.t()) :: [Ezagent.Message.t()]
  def messages_since(%URI{} = session_uri, %DateTime{} = last_seen_at) do
    MessageStore.in_session_since(session_uri, last_seen_at)
  end

  @doc "The latest durable monotonic message position for a session."
  @spec current_message_sequence(URI.t()) :: non_neg_integer()
  def current_message_sequence(%URI{} = session_uri) do
    MessageStore.current_session_sequence(session_uri)
  end

  @doc "Messages strictly after a durable session sequence, ascending."
  @spec messages_after_sequence(URI.t(), non_neg_integer()) :: [Ezagent.Message.t()]
  def messages_after_sequence(%URI{} = session_uri, sequence)
      when is_integer(sequence) and sequence >= 0 do
    MessageStore.in_session_after_sequence(session_uri, sequence)
  end

  @doc """
  All users in `workspace_uri` (decoded rows) — the framework-internal
  workspace user enumeration used by the session member-cap reconcile
  candidate scan. Delegates to `Ezagent.Users.list_in_workspace/1`.
  """
  @spec users_in_workspace(URI.t() | String.t()) :: [Ezagent.Users.decoded()]
  def users_in_workspace(workspace_uri) do
    Ezagent.Users.list_in_workspace(workspace_uri)
  end

  @doc """
  All agent instance URIs in `workspace_uri` — the framework-internal
  workspace agent enumeration used by the session member-cap reconcile
  candidate scan. Delegates to `Ezagent.Entity.Agent.list_in_workspace/1`.
  """
  @spec agents_in_workspace(URI.t()) :: [URI.t()]
  def agents_in_workspace(%URI{} = workspace_uri) do
    Ezagent.Entity.Agent.list_in_workspace(workspace_uri)
  end
end
