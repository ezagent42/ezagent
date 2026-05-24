defmodule Ezagent.ExternalMirror.WorkerRegistry do
  @moduledoc """
  `Ezagent.ExternalMirror.WorkerRegistry` — stdlib `Registry` used as
  the per-binding uniqueness gate for `PerBindingSupervisor`
  processes.

  SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  §3.1 + §9 PR-EM-2 — r5 codex round-4 HIGH-3 fix.

  ## Why a Registry, not DynamicSupervisor child id

  `DynamicSupervisor` does NOT enforce uniqueness via child id — the
  child spec's `:id` is opaque to the supervisor's start logic. A
  bare `DynamicSupervisor.start_child/2` for the same binding twice
  would silently spawn two PerBindingSupervisor instances (each
  with their own Worker child + own subscription to the Session
  Publisher), causing duplicate publishes and a corrupted slice.

  By using the Registry as the `name:` registration in
  `PerBindingSupervisor`'s child spec
  (`{:via, Registry, {WorkerRegistry, binding_uri}}`), concurrent
  `start_child` calls for the same `binding_uri` collide on the
  Registry and the SECOND call gets
  `{:error, {:already_started, pid}}` — Registry-enforced. The
  reconciler treats that error as success (idempotency contract
  per §3.1).

  ## Key shape

  The key is the full Worker Kind URI string —
  `entity://worker/<workspace>/em_<hash>` (per §7.2). Cross-workspace
  bindings cannot collide because the workspace segment is part of
  the URI hash input.

  ## Started by

  `EzagentDomainExternalMirror.Application` lists this Registry as
  a child BEFORE `RootSupervisor` so PerBindingSupervisor
  registrations land in an existing table.
  """

  @doc """
  Standard `Registry` child spec for `:unique` + `keys: :unique`.
  Pulled out as a function so the Application's `children/0` list
  reads naturally.
  """
  @spec child_spec(any()) :: Supervisor.child_spec()
  def child_spec(_init_arg) do
    Registry.child_spec(keys: :unique, name: __MODULE__)
  end

  @doc """
  Look up the PerBindingSupervisor pid for `binding_uri`. Returns
  `{:ok, pid}` or `:error`.

  Used by `Ezagent.ExternalMirror.WorkerSpawn.terminate/1` (graceful
  unbind path in PR-EM-3) and by the two-tier shape invariant test
  (PR-EM-2 acceptance test 3) to enumerate live per-binding
  supervisors.
  """
  @spec lookup(binding_uri :: String.t()) :: {:ok, pid()} | :error
  def lookup(binding_uri) when is_binary(binding_uri) do
    case Registry.lookup(__MODULE__, binding_uri) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc """
  Return every `{binding_uri, sup_pid}` currently registered. Used
  by the per-binding isolation regression test (PR-EM-2 acceptance
  test 2) to enumerate live PerBindingSupervisor children of the
  RootSupervisor without depending on `Supervisor.which_children`
  ordering.
  """
  @spec list_all() :: [{String.t(), pid()}]
  def list_all do
    Registry.select(__MODULE__, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
  end
end
