defmodule Ezagent.ActionSet.Introspection do
  @moduledoc false

  @spec new_style?(module()) :: boolean()
  def new_style?(mod) when is_atom(mod) do
    function_exported?(mod, :__behavior__?, 0) and apply(mod, :__behavior__?, [])
  end

  @doc """
  List the action names declared by a new-style Behavior module.
  Returns `[]` for legacy modules.
  """
  @spec action_names(module()) :: [atom()]
  def action_names(mod) when is_atom(mod) do
    if function_exported?(mod, :__action_names__, 0) do
      apply(mod, :__action_names__, [])
    else
      []
    end
  end

  @doc """
  Look up the full action spec for a new-style Behavior's action.
  Returns `nil` if not declared.
  """
  @spec action_spec(module(), atom()) :: map() | nil
  def action_spec(mod, action) when is_atom(mod) and is_atom(action) do
    if function_exported?(mod, :__action_spec__, 1) do
      apply(mod, :__action_spec__, [action])
    else
      nil
    end
  end

  # ---------------------------------------------------------------
  # Legacy helpers (existed pre-SPEC; preserved)
  # ---------------------------------------------------------------

  @doc """
  Look up the `data_owner/1` URI for the given Behavior + instance
  via the CapabilityRegistry.

  Re-exported on `Ezagent.ActionSet` so plugin Behavior modules can
  introspect data ownership WITHOUT depending on
  `Ezagent.CapabilityRegistry` directly — that direct dependency
  is banned by SPEC #445 §11 Gate 6 (plugin Behaviors only talk to
  the public `Ezagent.ActionSet` surface; the registry is an
  implementation detail of the runtime).

  Returns the same shape `CapabilityRegistry.data_owner_of/2`
  returns: `URI.t() | :any | :no_owner | {:scope, atom(), URI.t()}`.

  Added 2026-05-29 — closes §11 Gate 6 in `identity.ex` without
  forcing the lookup through a fake `:dispatch_returning` effect
  (the call is a pure synchronous callback introspection — no Kind
  is consulted, no slice is read).
  """
  @spec data_owner_of(module(), URI.t() | :any | {atom(), URI.t()}) ::
          URI.t() | :any | :no_owner | {:scope, atom(), URI.t()}
  def data_owner_of(behavior, instance) when is_atom(behavior) do
    # C5 §3.4 AuthzPort — data-owner resolution goes through the
    # config-resolved port, never the literal `Ezagent.CapabilityRegistry`
    # spine. Wired at core boot (`Ezagent.Kind.Adapters.wire!/0`) to
    # `Ezagent.Kind.Adapters.AuthzAdapter`.
    authz().data_owner_of(behavior, instance)
  end

  # C5 §3.4 AuthzPort accessor (see `data_owner_of/2` above).
  defp authz, do: Application.fetch_env!(:ezagent_actor, :authz)

  @doc """
  Read `reads_sibling_slices/0` from `behavior_module`, defaulting
  to `[]` when the optional callback is not exported.

  Used by `Ezagent.Kind.Runtime.handle_dispatch/4` to decide which
  sibling slices to expose via `ctx[:sibling_slices]`.
  """
  @spec reads_sibling_slices_of(module()) :: [atom()]
  def reads_sibling_slices_of(behavior_module) when is_atom(behavior_module) do
    if function_exported?(behavior_module, :reads_sibling_slices, 0) do
      behavior_module.reads_sibling_slices()
    else
      []
    end
  end

  @doc """
  Lifecycle Phase A (SPEC §2.2, F2) — the UNION of a Behavior's declared
  sibling-read keys across BOTH the legacy `reads_sibling_slices/0` and
  the Lifecycle `reads_siblings/0` callbacks.

  Used by `Ezagent.Kind.Runtime.handle_dispatch/4` to decide which
  sibling slices to surface on `ctx.sibling_slices` (legacy reader
  surface) AND `ctx.siblings` (Lifecycle reader surface). Reading the
  union means a module mid-migration that has renamed its callback —
  or a Kind composing one legacy + one Lifecycle Behavior — is correct
  regardless of which callback name each declares.
  """
  @spec reads_siblings_of(module()) :: [atom()]
  def reads_siblings_of(behavior_module) when is_atom(behavior_module) do
    legacy =
      if function_exported?(behavior_module, :reads_sibling_slices, 0),
        do: behavior_module.reads_sibling_slices(),
        else: []

    lifecycle =
      if function_exported?(behavior_module, :reads_siblings, 0),
        do: behavior_module.reads_siblings(),
        else: []

    (legacy ++ lifecycle) |> Enum.uniq()
  end

  @doc """
  Read `cap_exempt_actions/0` from `behavior_module`, defaulting to `[]`
  when the optional callback is not exported.
  """
  @spec cap_exempt_actions_of(module()) :: [atom()]
  def cap_exempt_actions_of(behavior_module) when is_atom(behavior_module) do
    if function_exported?(behavior_module, :cap_exempt_actions, 0) do
      behavior_module.cap_exempt_actions()
    else
      []
    end
  end

  @doc """
  Read `workspace_scoped?/0` from `behavior_module`, defaulting to `true`
  when the optional callback is not exported (per SPEC §2b — safer default).
  """
  @spec workspace_scoped?(module()) :: boolean()
  def workspace_scoped?(behavior_module) when is_atom(behavior_module) do
    if function_exported?(behavior_module, :workspace_scoped?, 0) do
      behavior_module.workspace_scoped?()
    else
      true
    end
  end
end
