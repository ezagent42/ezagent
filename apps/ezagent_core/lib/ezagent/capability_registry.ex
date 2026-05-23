defmodule Ezagent.CapabilityRegistry do
  @moduledoc """
  Non-bypassable source of truth for cap subjects + default grants.

  ## Why this exists

  Before this module, `Ezagent.BehaviorRegistry.register/3` was a bare
  ETS insert any code could call — no central enumeration of "what
  caps can be granted", no way to declare a cap-only subject
  (Presence-style auth gate without dispatch), no machine-checkable
  prevention of drift between cap subjects and dispatch entries.

  Per SPEC `docs/superpowers/specs/2026-05-23-capability-registry.md`
  rev 4 + Allen's "registry is sole entry, non-bypassable" directive:

  - `register/3` is the SINGLE entry point for new cap-subject
    declarations. `BehaviorRegistry.register/3` is `@doc false` and
    forbidden in production code outside this module (enforced by
    `single_capability_registration_entry_test.exs`).
  - Every Behavior MUST implement `cap_subjects/0` declaring its
    actions + descriptions (compile warning via `@behaviour` callback;
    CI's `--warnings-as-errors` turns warning into failure).
  - Behaviors may implement `dispatchable?/0` (optional; default
    `true`). Cap-only Behaviors (Presence's `:online`) return `false` —
    `register/3` then writes ONLY to the subjects table, skipping
    BehaviorRegistry so dispatch can never accidentally invoke them.

  ## Discovery

  `list_grantable/0` returns every registered subject — used by
  `/admin/caps` LV (renders the cap surface) and the future `mix
  ezagent.caps.list` CLI. `needed_for/3` returns the 4-field needed-cap
  map used by `Capability.matches?/2` — the same shape
  `Capability.cap_for_action/3` returns today, so Presence and any
  future cap-only consumer feeds it into the standard authorization
  path uniformly.

  ## Default grants

  Each Kind that has a default-grant policy (today: `Ezagent.Entity.User`)
  registers its grant_fn via `register_default_grant/2` at boot.
  `default_grants_for/2` returns the fn's result. The Kind's existing
  `default_caps/1` function STAYS (existing callers continue working);
  this primitive just makes the registry aware of it.
  """

  alias Ezagent.{BehaviorRegistry, Capability}
  alias Ezagent.CapabilityRegistry.{Defaults, Subjects}

  @typedoc "Internal subject record returned by `list_grantable/0`."
  @type subject :: %{
          kind: module(),
          behavior: module(),
          action: atom(),
          dispatchable?: boolean(),
          description: String.t()
        }

  # ----- Registration --------------------------------------------------------

  @doc """
  Register one `(kind, action, behavior)` triple — the SINGLE entry
  point for cap-subject + dispatch declarations.

  Reads `behavior.cap_subjects/0` to look up the description for
  `action`; reads `behavior.dispatchable?/0` (defaults to `true` if
  the optional callback isn't defined).

  - Always inserts subject `{{kind, behavior, action}, %{description,
    dispatchable?}}` into the subjects table.
  - If `dispatchable?/0 == true`, ALSO inserts `{{kind, action},
    behavior}` into `BehaviorRegistry` (for `Invocation.dispatch/1`).
  - RAISES `RuntimeError` if a DIFFERENT behavior is already registered
    for the same `{kind, action}` (conflict — caller bug).
  - RAISES `RuntimeError` if `action` is NOT declared in
    `behavior.cap_subjects/0` (forces description discipline).
  - Idempotent on repeat with the SAME `(kind, action, behavior)`.

  Intended caller: domain/plugin Application `start/2` + `Ezagent.Plugin.boot/1`.
  """
  @spec register(kind :: module(), action :: atom(), behavior :: module()) :: :ok
  def register(kind, action, behavior)
      when is_atom(kind) and is_atom(action) and is_atom(behavior) do
    description = lookup_description!(behavior, action)
    dispatchable? = behavior_dispatchable?(behavior)

    check_conflict!(kind, action, behavior)

    :ets.insert(
      Subjects.table(),
      {{kind, behavior, action}, %{description: description, dispatchable?: dispatchable?}}
    )

    if dispatchable? do
      # Single legitimate use of the raw BehaviorRegistry.register/3 —
      # all other production code must route through here.
      :ok = BehaviorRegistry.register(kind, action, behavior)
    end

    :ok
  end

  @doc """
  Register a default-grant policy for new instances of `kind`. `grant_fn`
  receives the spawn-time `workspace_uri` and returns the list of caps
  the new instance should receive.

  Intended caller: domain Application `start/2`. E.g.
  `EzagentDomainIdentity.Application` calls
  `register_default_grant(Ezagent.Entity.User, &Ezagent.Entity.User.default_caps/1)`.
  """
  @spec register_default_grant(
          kind :: module(),
          grant_fn :: (URI.t() | :any -> [Capability.t()])
        ) :: :ok
  def register_default_grant(kind, grant_fn)
      when is_atom(kind) and is_function(grant_fn, 1) do
    :ets.insert(Defaults.table(), {kind, grant_fn})
    :ok
  end

  # ----- Discovery / lookup --------------------------------------------------

  @doc """
  All registered cap subjects, sorted by `{kind, behavior, action}`.
  Used by `/admin/caps` LV + future `mix ezagent.caps.list`.
  """
  @spec list_grantable() :: [subject()]
  def list_grantable() do
    Subjects.table()
    |> :ets.tab2list()
    |> Enum.map(fn {{kind, behavior, action}, %{description: d, dispatchable?: disp?}} ->
      %{
        kind: kind,
        behavior: behavior,
        action: action,
        description: d,
        dispatchable?: disp?
      }
    end)
    |> Enum.sort_by(&{&1.kind, &1.behavior, &1.action})
  end

  @doc "Subjects registered against a specific Kind."
  @spec subjects_for_kind(module()) :: [subject()]
  def subjects_for_kind(kind) when is_atom(kind) do
    Enum.filter(list_grantable(), &(&1.kind == kind))
  end

  @doc """
  Look up a single subject by `{kind, action}`. Returns `:error` if no
  subject is registered. There can be at most one subject per
  `{kind, action}` (conflict-detected by `register/3`).
  """
  @spec lookup_subject(module(), atom()) :: {:ok, subject()} | :error
  def lookup_subject(kind, action) when is_atom(kind) and is_atom(action) do
    case :ets.match_object(Subjects.table(), {{kind, :_, action}, :_}) do
      [{{^kind, behavior, ^action}, %{description: d, dispatchable?: disp?}}] ->
        {:ok,
         %{
           kind: kind,
           behavior: behavior,
           action: action,
           description: d,
           dispatchable?: disp?
         }}

      [] ->
        :error
    end
  end

  @doc """
  Return the 4-field needed-cap MAP (NOT a `%Capability{}` struct) for
  authorization against `target_uri`. Same shape
  `Ezagent.Capability.cap_for_action/3` returns today.

  RAISES `KeyError` if `{kind, action}` is not registered.
  """
  @spec needed_for(module(), atom(), URI.t()) :: %{
          kind: atom(),
          behavior: module(),
          instance: URI.t(),
          workspace_uri: URI.t() | :any
        }
  def needed_for(kind_module, action, %URI{} = target_uri)
      when is_atom(kind_module) and is_atom(action) do
    case lookup_subject(kind_module, action) do
      {:ok, %{behavior: behavior}} ->
        %{
          kind: kind_module.type_name(),
          behavior: behavior,
          instance: Ezagent.URI.instance(target_uri),
          workspace_uri: Capability.workspace_of(target_uri)
        }

      :error ->
        raise KeyError,
          key: {kind_module, action},
          term: "no cap subject registered for #{inspect(kind_module)} :#{action}"
    end
  end

  @doc """
  Default caps a fresh instance of `kind` in `workspace_uri` would get.
  Returns `[]` if no default-grant fn is registered for `kind`.
  """
  @spec default_grants_for(module(), URI.t() | :any) :: [Capability.t()]
  def default_grants_for(kind, workspace_uri) when is_atom(kind) do
    case :ets.lookup(Defaults.table(), kind) do
      [{^kind, grant_fn}] -> grant_fn.(workspace_uri)
      [] -> []
    end
  end

  @doc """
  Returns the list of every Kind that has a registered default-grant
  fn. Used by `/admin/caps` LV to enumerate the default-grants section
  without reaching into internal ETS state.
  """
  @spec kinds_with_default_grants() :: [module()]
  def kinds_with_default_grants do
    Defaults.table()
    |> :ets.tab2list()
    |> Enum.map(fn {kind, _fn} -> kind end)
    |> Enum.sort()
  end

  # ----- Private -------------------------------------------------------------

  defp lookup_description!(behavior, action) do
    case Enum.find(behavior.cap_subjects(), fn {a, _desc} -> a == action end) do
      {^action, description} when is_binary(description) ->
        description

      nil ->
        raise RuntimeError,
              "#{inspect(behavior)}.cap_subjects/0 does not declare " <>
                "action #{inspect(action)} — every registered action must " <>
                "appear in cap_subjects/0 with a description (see SPEC §3.1)"
    end
  end

  # Optional callback probe — Behaviors that don't define `dispatchable?/0`
  # default to `true` (the common case; only cap-only Behaviors like
  # Presence override).
  defp behavior_dispatchable?(behavior) do
    if function_exported?(behavior, :dispatchable?, 0) do
      behavior.dispatchable?()
    else
      true
    end
  end

  defp check_conflict!(kind, action, new_behavior) do
    case :ets.match_object(Subjects.table(), {{kind, :_, action}, :_}) do
      [] ->
        :ok

      [{{^kind, ^new_behavior, ^action}, _}] ->
        :ok

      [{{^kind, other_behavior, ^action}, _}] ->
        raise RuntimeError,
              "Capability subject conflict: #{inspect(kind)} :#{action} " <>
                "is already registered to #{inspect(other_behavior)}; " <>
                "cannot re-register to #{inspect(new_behavior)}. " <>
                "Same {kind, action} mapped to two different behaviors " <>
                "is a caller bug — find the dup and decide which is correct."
    end
  end
end
