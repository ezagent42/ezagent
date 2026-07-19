defmodule Ezagent.CapabilityRegistry do
  @moduledoc """
  Non-bypassable source of truth for cap subjects + default grants.

  ## Why this exists

  Before this module, `Ezagent.BehaviorRegistry.register/3` was a bare
  ETS insert any code could call — no central enumeration of "what
  caps can be granted", no way to declare a cap-only subject
  (a cap-only auth gate without dispatch), no machine-checkable
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
    `true`). Cap-only Behaviors (Notifications's `:subscribe`) return `false` —
    `register/3` then writes ONLY to the subjects table, skipping
    BehaviorRegistry so dispatch can never accidentally invoke them.

  ## Discovery

  `list_grantable/0` returns every registered subject — used by
  `/admin/caps` LV (renders the cap surface) and the future `mix
  ezagent.caps.list` CLI. `needed_for/3` returns the 4-field needed-cap
  map used by `Capability.matches?/2` — the same shape
  `Capability.cap_for_action/3` returns today, so cap-only consumers
  feed it into the standard authorization
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
    case register_owned(kind, action, behavior) do
      receipt when receipt in [:acquired, :existing_identical] ->
        :ok

      {:error, {:capability_subject_conflict, ^kind, ^action, existing, ^behavior}} ->
        raise RuntimeError,
              "Capability subject conflict: #{inspect(kind)} :#{action} is already " <>
                "registered to #{inspect(existing)}; cannot re-register to #{inspect(behavior)}"

      {:error, reason} ->
        raise RuntimeError, inspect(reason)
    end
  end

  @doc """
  Atomically register a subject and report whether this call acquired it.

  The receipt lets application boot rollback only declarations inserted by that
  boot attempt. Mutation of the two registry tables is serialized under one
  registry lock; this does not claim atomicity with any other registry.
  """
  @spec register_owned(module(), atom(), module()) ::
          :acquired | :existing_identical | {:error, term()}
  def register_owned(kind, action, behavior)
      when is_atom(kind) and is_atom(action) and is_atom(behavior) do
    :global.trans({__MODULE__, :mutation}, fn ->
      register_owned_locked(kind, action, behavior)
    end)
  end

  defp register_owned_locked(kind, action, behavior) do
    description = lookup_description!(behavior, action)
    dispatchable? = behavior_dispatchable?(behavior)

    subject_before = lookup_subject_raw(kind, action)
    behavior_before = lookup_behavior_raw(kind, action)

    with :ok <- compatible_subject(subject_before, kind, action, behavior),
         :ok <- compatible_behavior(behavior_before, kind, action, behavior, dispatchable?) do
      receipt =
        if match?({:ok, _}, subject_before) or match?({:ok, _}, behavior_before) do
          :existing_identical
        else
          :acquired
        end

      try do
        :ets.insert(
          Subjects.table(),
          {{kind, behavior, action}, %{description: description, dispatchable?: dispatchable?}}
        )

        if dispatchable? do
          :ok = BehaviorRegistry.register(kind, action, behavior)
        end

        receipt
      catch
        class, reason ->
          restore_pair(kind, action, subject_before, behavior_before)
          :erlang.raise(class, reason, __STACKTRACE__)
      end
    end
  end

  defp compatible_subject(:error, _kind, _action, _behavior), do: :ok
  defp compatible_subject({:ok, %{behavior: behavior}}, _kind, _action, behavior), do: :ok

  defp compatible_subject({:ok, %{behavior: existing}}, kind, action, behavior),
    do: {:error, {:capability_subject_conflict, kind, action, existing, behavior}}

  defp compatible_behavior(:error, _kind, _action, _behavior, _dispatchable?), do: :ok

  defp compatible_behavior({:ok, behavior}, _kind, _action, behavior, true), do: :ok

  defp compatible_behavior({:ok, existing}, kind, action, behavior, _dispatchable?),
    do: {:error, {:behavior_registry_conflict, kind, action, existing, behavior}}

  defp restore_pair(kind, action, subject_before, behavior_before) do
    :ets.match_delete(Subjects.table(), {{kind, :_, action}, :_})

    case subject_before do
      {:ok, %{behavior: old_behavior, description: description, dispatchable?: dispatchable?}} ->
        :ets.insert(
          Subjects.table(),
          {{kind, old_behavior, action},
           %{description: description, dispatchable?: dispatchable?}}
        )

      :error ->
        :ok
    end

    :ok = BehaviorRegistry.unregister(kind, action)

    case behavior_before do
      {:ok, old_behavior} -> BehaviorRegistry.register(kind, action, old_behavior)
      :error -> :ok
    end
  end

  @doc """
  Unregister a `(kind, action, behavior)` triple — the reverse of
  `register/3`, used by the plugin-package UNLOAD path (handoff piece 4).

  Removes BOTH:
  - the cap-subject row `{{kind, behavior, action}, _}` from the
    subjects table, AND
  - the dispatch row `{{kind, action}, behavior}` from
    `BehaviorRegistry` (so `Invocation.dispatch/1` stops routing to
    the now-unloaded behavior → `{:error, {:unknown_action, action}}`).

  Idempotent. Only removes the row if it still points at `behavior`
  (defense in depth: a swap that already re-registered a NEW behavior
  for the same `{kind, action}` is NOT clobbered by a late v1 unload).
  """
  @spec unregister(kind :: module(), action :: atom(), behavior :: module()) :: :ok
  def unregister(kind, action, behavior)
      when is_atom(kind) and is_atom(action) and is_atom(behavior) do
    :global.trans({__MODULE__, :mutation}, fn ->
      case {lookup_subject_raw(kind, action), lookup_behavior_raw(kind, action)} do
        {{:ok, %{behavior: ^behavior, dispatchable?: true}}, {:ok, ^behavior}} ->
          :ets.delete(Subjects.table(), {kind, behavior, action})
          :ok = BehaviorRegistry.unregister(kind, action)

        {{:ok, %{behavior: ^behavior, dispatchable?: false}}, :error} ->
          :ets.delete(Subjects.table(), {kind, behavior, action})

        _ ->
          :ok
      end

      :ok
    end)
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
    case lookup_subject_raw(kind, action) do
      {:ok, subject} ->
        {:ok, subject}

      :error ->
        # #533 §3.4 — universal behaviors (e.g. Ezagent.ActionSet.Manage)
        # are grantable on EVERY Kind by construction. On a per-Kind miss,
        # synthesize the subject for the universal behavior handling this
        # action (a per-Kind registration above always wins).
        case Ezagent.UniversalBehaviors.behavior_for_action(action) do
          nil ->
            :error

          behavior ->
            {:ok,
             %{
               kind: kind,
               behavior: behavior,
               action: action,
               description: lookup_description!(behavior, action),
               dispatchable?: behavior_dispatchable?(behavior)
             }}
        end
    end
  end

  defp lookup_subject_raw(kind, action) do
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

  defp lookup_behavior_raw(kind, action) do
    case :ets.lookup(BehaviorRegistry.table(), {kind, action}) do
      [{{^kind, ^action}, behavior}] -> {:ok, behavior}
      [] -> :error
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
          action: atom(),
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
          # SPEC 2026-05-27 capability-action-axis — propagate the
          # concrete action into the needed-cap shape (matches the
          # dispatch chokepoint's `cap_for_action/3` post-SPEC).
          action: action,
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
  # Notifications override).
  defp behavior_dispatchable?(behavior) do
    if function_exported?(behavior, :dispatchable?, 0) do
      behavior.dispatchable?()
    else
      true
    end
  end

  # =================================================================
  # PR-OWN-1 — data-ownership formalism
  # docs/superpowers/specs/2026-05-24-caps-data-ownership-v2.md §4
  # =================================================================

  @doc """
  Probe `behavior.data_owner(instance)` if exported, else return
  `:no_owner` (the safe default for Behaviors that haven't migrated
  yet — PR-OWN-2..6 sweeps them).

  See `Ezagent.ActionSet` `data_owner/1` callback for the contract.
  """
  @spec data_owner_of(
          behavior :: module(),
          instance ::
            URI.t() | :any | {atom(), URI.t()}
        ) ::
          URI.t() | :any | :no_owner | {:scope, atom(), URI.t()}
  def data_owner_of(behavior, instance) when is_atom(behavior) do
    if function_exported?(behavior, :data_owner, 1) do
      behavior.data_owner(instance)
    else
      :no_owner
    end
  end

  @doc """
  Authorize issuance of `cap` against authority loaded for the issuer.

  `context` contains the accountable `:caller`. All inputs are structural;
  domain code contributes only Behavior `data_owner/1` callback data through
  `data_owner_of/2`.
  """
  @spec authorize_grant(MapSet.t(Capability.t()) | [Capability.t()], Capability.t(), map()) ::
          :ok | {:error, term()}
  def authorize_grant(caps, %Capability{} = cap, context) when is_map(context) do
    held = normalize_authority_caps(caps)

    with :ok <- authorize_action_axis(held, cap),
         :ok <- authorize_cap_shape(held, cap, Map.get(context, :caller)) do
      :ok
    end
  end

  @doc "True when a rule-issued capability is structurally bounded."
  @spec rule_cap_bounded?(Capability.t()) :: boolean()
  def rule_cap_bounded?(%Capability{} = cap) when cap.kind == :any, do: false
  def rule_cap_bounded?(%Capability{} = cap) when cap.behavior == :any, do: false

  def rule_cap_bounded?(%Capability{instance: instance} = cap) do
    scope_bounded_instance?(instance) or
      (match?(%URI{}, instance) and Capability.action_of(cap) != :any)
  end

  defp authorize_action_axis(held, %Capability{} = cap) do
    cond do
      Capability.action_of(cap) != :any -> :ok
      scope_bounded_instance?(cap.instance) -> :ok
      admin_caps?(held) -> :ok
      true -> {:error, :wildcard_action_grant_requires_admin_authority}
    end
  end

  defp authorize_cap_shape(held, %Capability{} = cap, _caller)
       when cap.kind == :any and cap.behavior == :any and cap.instance == :any and
              cap.workspace_uri == :any do
    require_admin(held, :grant_wildcard_requires_admin)
  end

  defp authorize_cap_shape(held, %Capability{} = cap, _caller) when cap.kind == :any,
    do: require_workspace_admin(held, cap.workspace_uri)

  defp authorize_cap_shape(held, %Capability{} = cap, _caller) when cap.behavior == :any,
    do: require_workspace_admin(held, cap.workspace_uri)

  defp authorize_cap_shape(
         held,
         %Capability{behavior: behavior, instance: instance, workspace_uri: ws} = cap,
         caller
       )
       when is_atom(behavior) do
    if Code.ensure_loaded?(behavior) and function_exported?(behavior, :data_owner, 1) do
      case data_owner_of(behavior, instance) do
        %URI{} = owner ->
          cond do
            caller == owner -> :ok
            admin_caps?(held) -> :ok
            manages_target?(held, instance) -> require_delegable(held, cap)
            true -> {:error, :grant_not_owner}
          end

        :any ->
          require_workspace_admin(held, ws)

        _ ->
          require_admin(held, :grant_owner_unresolvable)
      end
    else
      :ok
    end
  end

  defp authorize_cap_shape(_held, _cap, _caller), do: :ok

  defp require_delegable(held, %Capability{} = cap) do
    needed = %{
      kind: cap.kind,
      behavior: cap.behavior,
      action: Capability.action_of(cap),
      instance: cap.instance,
      workspace_uri: cap.workspace_uri
    }

    if Enum.any?(held, &Capability.matches?(&1, needed)),
      do: :ok,
      else: {:error, :grant_not_delegable}
  end

  defp require_admin(held, error), do: if(admin_caps?(held), do: :ok, else: {:error, error})

  defp require_workspace_admin(held, :any) do
    if admin_caps?(held) or cross_workspace_admin?(held),
      do: :ok,
      else: {:error, :grant_workspace_any_requires_admin}
  end

  defp require_workspace_admin(held, %URI{} = ws) do
    if admin_caps?(held) or workspace_admin?(held, ws),
      do: :ok,
      else: {:error, :grant_workspace_admin_required}
  end

  defp require_workspace_admin(_held, _ws), do: {:error, :grant_workspace_uri_invalid}

  defp admin_caps?(held) do
    Enum.any?(held, fn
      %Capability{} = cap ->
        cap.kind == :any and cap.behavior == :any and cap.action == :any and
          cap.instance == :any and cap.workspace_uri == :any

      _ ->
        false
    end)
  end

  defp cross_workspace_admin?(held) do
    workspace = Module.concat([Ezagent, ActionSet, Workspace])

    Enum.any?(held, fn
      %Capability{
        kind: :workspace,
        behavior: ^workspace,
        action: :any,
        instance: :any,
        workspace_uri: :any
      } ->
        true

      _ ->
        false
    end)
  end

  defp workspace_admin?(held, ws) do
    workspace = Module.concat([Ezagent, ActionSet, Workspace])

    Enum.any?(held, fn
      %Capability{behavior: ^workspace, action: :any, workspace_uri: ^ws} -> true
      %Capability{behavior: ^workspace, action: :any, workspace_uri: :any} -> true
      _ -> false
    end)
  end

  defp manages_target?(held, instance) do
    target =
      case instance do
        {_scope, %URI{} = uri} -> uri
        other -> other
      end

    Enum.any?(held, fn
      %Capability{behavior: Ezagent.ActionSet.Manage} = cap ->
        Capability.action_of(cap) == :any and held_instance_covers?(cap, target)

      _ ->
        false
    end)
  end

  defp held_instance_covers?(%Capability{} = held, %URI{} = target) do
    Capability.matches?(held, %{
      kind: held.kind,
      behavior: held.behavior,
      action: Capability.action_of(held),
      instance: target,
      workspace_uri: held.workspace_uri
    })
  end

  defp held_instance_covers?(_held, _target), do: false

  defp scope_bounded_instance?({scope, %URI{}})
       when scope in [:within_session, :within_workspace, :spawned_by],
       do: true

  defp scope_bounded_instance?(_), do: false

  defp normalize_authority_caps(%MapSet{} = caps), do: MapSet.to_list(caps)
  defp normalize_authority_caps(caps) when is_list(caps), do: caps
  defp normalize_authority_caps(_), do: []

  @doc """
  Walk every Behavior registered against `kind`, ask each one
  `data_owner(target_uri)`, and return the list of
  `{grantee_uri, %Capability{}}` tuples to grant.

  Only concrete `%URI{}` owner returns produce a default grant:
  `:any` / `:no_owner` / `{:scope, _, _}` produce NO entry because
  those classes don't have a per-target owner — they rely on
  explicit `grant_cap` from the appropriate admin (per SPEC §3.3).

  Tuple form `{grantee, cap}` is mandatory because `%Capability{}`
  carries only `granted_by`, not the grantee field — the spawn
  caller needs `grantee` to know whose Identity slice receives the cap.

  Behavior enumeration goes via the public
  `subjects_for_kind/1` API (typed surface, includes BOTH
  dispatchable and cap-only Behaviors). Round-1 SPEC used
  `BehaviorRegistry.behaviors_for/1` which skipped cap-only;
  round-4 used a wrong raw ETS match shape; round-5 uses this
  public surface — lesson locked by SPEC §7 PR-OWN-1 acceptance
  test that asserts dispatchable + cap-only both return.
  """
  @spec default_grants_from_data_owner(
          kind :: module(),
          target_uri :: URI.t()
        ) ::
          [{URI.t(), Ezagent.Capability.t()}]
  def default_grants_from_data_owner(kind, %URI{} = target_uri) when is_atom(kind) do
    # Codex PR-OWN-1 HIGH fix: canonicalize the target_uri via
    # `Ezagent.URI.instance/1` BEFORE owner-lookup + cap-storage.
    # Dispatch-side `Capability.matches?/2` runs against the canonical
    # instance (no query string), so a cap stored on
    # `entity://user/acme/alice?action=identity.list_caps` would never
    # match the dispatch's canonical `entity://user/acme/alice`.
    # Round-1 tests only used bare URIs so this silent broken-grant
    # path wasn't covered — round-2 regression test below adds it.
    instance_uri = Ezagent.URI.instance(target_uri)

    # Codex PR-OWN-1 round-2 MEDIUM fix: derive `workspace_uri` from
    # the RAW `target_uri`, matching `Ezagent.Capability.cap_for_action/3`
    # exactly (capability.ex:494). If we derived from `instance_uri`
    # instead, `workspace://team-alpha/subresource?action=…` would canon-
    # icalize to `workspace://team-alpha` (path dropped), then yield
    # `workspace_uri: workspace://team-alpha` — but dispatch's
    # `cap_for_action` uses RAW target and `workspace_of(workspace://...)`
    # preserves the full path, so dispatch's needed cap would carry
    # `workspace_uri: workspace://team-alpha/subresource`. Mismatch on the
    # workspace dimension → cap silently fails `matches?/2`.
    workspace_uri =
      case Ezagent.Capability.workspace_of(target_uri) do
        %URI{} = ws -> ws
        :any -> :any
      end

    granter_uri = bootstrap_granter()

    kind
    |> subjects_for_kind()
    |> Enum.map(& &1.behavior)
    |> Enum.uniq()
    |> Enum.flat_map(fn behavior ->
      case data_owner_of(behavior, instance_uri) do
        %URI{} = owner_uri ->
          cap = %Ezagent.Capability{
            kind: kind_type_name(kind),
            behavior: behavior,
            # SPEC 2026-05-27 capability-action-axis — owner default
            # grants are behavior-wildcard (any action on the owned
            # Behavior). The granter is the bootstrap principal so
            # this is a legitimate admin-granted broad cap. Narrowing
            # to specific actions is a future PR — see §11 + the
            # PR #356 carve-out commentary at the migration block
            # below.
            action: :any,
            instance: instance_uri,
            workspace_uri: workspace_uri,
            granted_by: granter_uri,
            granted_at: DateTime.utc_now()
          }

          [{owner_uri, cap}]

        _other ->
          # :any | :no_owner | {:scope, _, _} → no default grant,
          # caller relies on explicit grant_cap.
          []
      end
    end)
  end

  # --- MIGRATION CONSTRAINT for PR-OWN-3+ (codex PR-OWN-1 MEDIUM) ---
  #
  # The `%Capability{}` struct has no `action` dimension (SPEC §1
  # CRITICAL-1 reframe: caps are behavior-scoped). Consequence: an
  # owner cap on a Behavior grants ALL actions of that Behavior.
  # For mixed-sensitivity Behaviors (e.g. `Behavior.Identity` whose
  # `cap_subjects/0` includes both safe `:list_caps` / `:has_cap?`
  # AND privileged `:grant_cap` / `:revoke_cap`), a single
  # behavior-scoped owner cap would let users self-mutate their own
  # caps — breaking the admin-only expectation for grant/revoke.
  #
  # MIGRATION RULE for PR-OWN-3 (Identity migration):
  # SPLIT `Behavior.Identity` BEFORE adding `data_owner/1`:
  #   - `Behavior.Identity` — owner-readable: :list_caps, :has_cap?
  #     (data_owner = the entity itself)
  #   - `Behavior.IdentityAdmin` — admin-only: :grant_cap,
  #     :revoke_cap (data_owner = :no_owner; bootstrap admin only,
  #     or workspace-admin via OQ-OWN-1 resolution)
  #
  # SAME RULE applies to any future multi-action Behavior where
  # owner-default grant of all actions would over-authorize. Apply
  # split-then-migrate per PR-OWN-3+ acceptance criterion.

  # The synthesized granter for PR-OWN-1 default grants. `Ezagent.Entity.User`
  # lives in `ezagent_domain_identity` which depends on `ezagent_core`,
  # so we can't reference it from here at compile time. Resolution via
  # `Code.ensure_loaded?/1` + `apply/3` at runtime so the dependency
  # arrow stays correct and the URI matches the real admin once domain.identity
  # is started.
  #
  # #154 genesis collapse: the fallback (User module not loaded, e.g. the
  # standalone ezagent_core test env) must NOT mint a `system://bootstrap/...`
  # granter — predicate A (`Capability.granted_by_entity?/1`) now rejects every
  # `system://`-granted cap, so such a default grant would be silently inert.
  # `Ezagent.Entity.User.admin_uri/0` is exactly `Ezagent.URI.user(:system,
  # :admin)` (entity://system/user/admin), which lives in ezagent_core and is
  # the canonical genesis admin entity — so the fallback returns the SAME
  # entity granter the primary branch would, keeping the cap live.
  defp bootstrap_granter do
    if Code.ensure_loaded?(Ezagent.Entity.User) and
         function_exported?(Ezagent.Entity.User, :admin_uri, 0) do
      apply(Ezagent.Entity.User, :admin_uri, [])
    else
      Ezagent.URI.user(:system, :admin)
    end
  end

  # Some test Kinds don't implement `type_name/0`; fall back to the
  # module atom so the cap struct still has a key.
  # `Code.ensure_loaded?/1` is required because `function_exported?/3`
  # returns false for not-yet-loaded modules (e.g. test-only Kinds
  # whose .ex file lives under `test/support/`).
  defp kind_type_name(kind) do
    if Code.ensure_loaded?(kind) and function_exported?(kind, :type_name, 0) do
      kind.type_name()
    else
      kind
    end
  end
end
