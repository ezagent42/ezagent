defmodule Ezagent.ActionSet.ConfigEvolve do
  @moduledoc """
  Agent-owned config evolution (spec `docs/superpowers/specs/2026-06-11-agent-owned-config-evolve-design.md`,
  rev 4). The agent mutates its OWN config under its own authority, dissolving
  the #607 confused-deputy: there is no longer a Session reaching across the
  entity boundary into an arbitrary agent's Sandbox under a god-cap.

  ## Two steps (rev-4 H1 — no intermediate projection action)

  - **STEP 1 `apply_config_delta` / `repoint_config`** — dispatched TO the
    agent, gated by the **agent's manage-cap** (`cap(:agent, Manage, :any)`;
    the runtime overwrites the needed-cap action with the dispatched action,
    so the held `Manage :any` cap matches). Writes the immutable object +
    pointer to `ConfigStore` (the DURABLE source of truth) synchronously,
    object→pointer ordered, `source_turn_id`-idempotent, and records the
    applied marker in this Behavior's own `:config_evolve` slice. Then, IN
    THE SAME handler, it reads the current Sandbox cascade (via
    `reads_siblings([:sandbox])`), computes the refreshed
    `respawn_template_data`, and emits ONE
    `{:dispatch_after_commit, Cmd(self, :update_config, rtd)}` — the deferred
    self-dispatch to **`sandbox.update_config`** (rev-4 H1: the dispatched
    action IS `:update_config`, matching the agent's self-scoped
    `cap(:agent, Sandbox, :update_config)` — there is no
    `project_cascade_to_sandbox` action whose action axis the runtime would
    overwrite).

  - **STEP 2** is therefore NOT a separate ConfigEvolve action — it is the
    deferred `sandbox.update_config` self-dispatch step 1 emits. Demoting the
    Sandbox pointer from source to spawn-cache keeps the spawn read path
    untouched.

  ## Boot reconciliation (crash-window self-heal)

  If the agent crashes between step 1's commit and the deferred
  `update_config` running, the Sandbox cache is stale. `activate/2` cannot emit
  effects and is NOT given sibling slices (the Lifecycle macro owns
  `post_init/2 → {:continue, :ezagent_activate} → handle_continue/3` and
  builds the activate ctx with no `:siblings`/`:caps`). So `activate/2`
  self-defers a `:ezagent_ce_reconcile` mailbox message (the ExternalMirror
  `activate → send(self(), …) → handle_signal/2` precedent — the macro's
  `post_init` is not overridable, so a second `{:continue, …}` is
  infeasible). `handle_signal/2` runs post-`:ready` and self-dispatches the
  `reconcile_cascade` ACTION (carrying the agent's OWN caps, read from its
  `:identity` slice via `ctx.slice_state`), whose handler — a full action
  ctx WITH `ctx.siblings[:sandbox]` — compares the `ConfigStore` pointer to
  the Sandbox cache and emits the SAME `Cmd(self, :update_config, rtd)` if they
  diverge. This closes the window in the agent's own domain (no
  `core→ConfigStore` dependency).

  ## Authority (§4)

  `apply_config_delta` / `repoint_config` → the agent's manage-cap (whoever
  manages the agent may evolve it; the membership-OR-lineage approximation
  is retired). `reconcile_cascade` → the agent's self-scoped
  `cap(:agent, ConfigEvolve, :reconcile_cascade)`. The emitted
  `sandbox.update_config` → the agent's self-scoped
  `cap(:agent, Sandbox, :update_config)`. The confused-deputy authority guard
  (`subject_uri` belongs to a manageable agent) is GONE because the agent
  IS the subject — there is no deputy.

  Owns the `:config_evolve` slice (`%{applied: %{turn_id => reply}}` —
  applied-turn idempotency markers; the durable config-version state lives
  in `ConfigStore`).
  """

  use Ezagent.Lifecycle

  alias Ezagent.Socialware.{ConfigProjection, ConfigStore}

  @layer_order ~w(workspace user session)
  @editable_layer "user"

  # rev-4: step 1 / reconcile read the agent's OWN Sandbox cascade in-process
  # (the genuine ApiKeys in-process read precedent) to compute the refreshed
  # respawn_template_data. Surfaced as `ctx.siblings[:sandbox]` on action ctx.
  #
  # `:identity` is ALSO declared because the deferred `sandbox.update_config`
  # self-dispatch must carry the AGENT's OWN caps (its self-scoped
  # `cap(:agent, Sandbox, :update_config)`), NOT the step-1 caller's (the
  # manager holds only the manage-cap). The agent's caps live in its own
  # `:identity` slice on the same Kind — read in-process via
  # `ctx.siblings[:identity][:caps]`.
  reads_siblings([:sandbox, :identity])

  # The cascade key the user layer is stored under. The delta carries its own
  # `key`; reconciliation needs a default to read the current pointer.
  @default_cascade_key "agent.soul"

  @ce_reconcile_signal :ezagent_ce_reconcile

  # `turn_id` is required (the idempotency marker); the delta fields are
  # OPTIONAL — they default to the agent's own user layer in the handler
  # (`attrs_from_args/3`). PR-3's Turn rewire forwards the settled delta's
  # `layer`/`workspace_uri`/`subject_uri`/`key`/`patch` explicitly.
  action(:apply_config_delta,
    args: %{
      turn_id: :string,
      layer: {:option, :atom},
      workspace_uri: {:option, :uri},
      subject_uri: {:option, :uri},
      key: {:option, :string},
      patch: {:option, :map},
      replace_body: {:option, :map}
    },
    returns: %{config_id: :string, previous_config_id: {:option, :string}},
    caps: [:apply_config_delta],
    modes: [:call],
    description: "Apply a settled config delta to THIS agent (step 1, durable)"
  )

  action(:repoint_config,
    args: %{
      layer: :atom,
      workspace_uri: :uri,
      subject_uri: :uri,
      key: :string,
      config_id: :string
    },
    returns: %{config_id: :string, previous_config_id: {:option, :string}},
    caps: [:repoint_config],
    modes: [:call],
    description: "Rollback/advance THIS agent's config pointer (step 1)"
  )

  # READ — the cap-gated config cascade read. Symmetric with the writes: the
  # console facade (`Ezagent.Agent.Config`) must NOT read `ConfigStore` directly
  # (an authorization asymmetry — anyone could read any agent's
  # `agent.soul` / soul_md). Routing the read through dispatch gates it on
  # the SAME agent manage-cap the writes use (step-5.5 enforcement, on the
  # caller's real caps, instance substituted to THIS agent), so the gate is
  # structural, not a hand-rolled facade check.
  action(:read_cascade,
    args: %{keys: {:option, {:list, :string}}},
    returns: %{cascade: :map},
    caps: [:read_cascade],
    modes: [:call],
    description: "Read THIS agent's editable config cascade (manage-cap gated)"
  )

  action(:reconcile_cascade,
    args: %{},
    returns: %{reconciled: :boolean},
    caps: [:reconcile_cascade],
    modes: [:cast],
    description:
      "Reconcile the agent's Sandbox cache against the durable ConfigStore " <>
        "pointer (boot self-heal); emits sandbox.update_config if divergent"
  )

  # rev-4 (H1): each declared cap's ACTION equals the dispatched action it
  # gates (the runtime overwrites the needed-cap action with the dispatched
  # action at runtime.ex:466-476, so a mismatched action never matches).
  #
  #   apply_config_delta / repoint_config → cap(:agent, Manage, :any)
  #     the runtime overwrites the action to the dispatched one; the manager's
  #     held cap(:agent, Manage, :any, instance: agent) has action :any which
  #     matches anything → authorized.
  #   reconcile_cascade → cap(:agent, ConfigEvolve, :reconcile_cascade)  (self)
  #
  # The sandbox write step 1 / reconcile emit is a Cmd(self, :update_config, …),
  # gated by cap(:agent, Sandbox, :update_config) — the agent holds it over
  # itself (granted at create, see Ezagent.ActionSet.Identity.create/1).
  def required_caps do
    %{
      apply_config_delta: Ezagent.Capability.cap(:agent, Ezagent.ActionSet.Manage, :any),
      repoint_config: Ezagent.Capability.cap(:agent, Ezagent.ActionSet.Manage, :any),
      # READ is gated by the SAME agent manage-cap as the writes — "whoever
      # manages the agent may read its config" (the runtime overwrites the
      # needed-cap action to the dispatched `:read_cascade`; the manager's held
      # cap(:agent, Manage, :any, instance: agent) has action :any → matches).
      read_cascade: Ezagent.Capability.cap(:agent, Ezagent.ActionSet.Manage, :any),
      reconcile_cascade: Ezagent.Capability.cap(:agent, __MODULE__, :reconcile_cascade)
    }
  end

  # data_owner/1 — the agent owns its own config-evolve state.
  @spec data_owner(URI.t() | :any | term()) :: URI.t() | :any | :no_owner
  def data_owner(%URI{scheme: "entity"} = agent_uri), do: Ezagent.URI.instance(agent_uri)
  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner

  # ---- create/1 — PERSISTENT state (applied-turn markers) ------------------

  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{applied: %{}}}

  # ---- activate/2 — schedule the boot reconcile (crash-window self-heal) ----
  #
  # `activate/2` runs PRE-`:ready` with NO `:siblings`/`:caps` in ctx and may
  # only return transients (no effects). It therefore CANNOT do the reconcile
  # directly. Per §10-R1 (ExternalMirror precedent) it self-defers a mailbox
  # message; `handle_signal/2` runs post-`:ready` and self-dispatches the
  # `reconcile_cascade` action (full ctx). `send(self(), …)` is the only work
  # done here. No transients to rebuild.
  @impl Ezagent.Lifecycle
  def activate(_state, _ctx) do
    send(self(), @ce_reconcile_signal)
    {:ok, %{}}
  end

  # ---- handle_signal/2 — post-`:ready` reconcile kick ----------------------
  #
  # The deferred `:ezagent_ce_reconcile` message scheduled from `activate/2`.
  # `handle_signal/2`'s ctx carries `ctx.slice_state` (all slices, read-only)
  # but NO `:siblings`/`:caps`, so it cannot itself read the sandbox sibling
  # or authorize a dispatch. It self-dispatches the `reconcile_cascade`
  # ACTION instead (an action dispatch builds the full ctx WITH siblings),
  # carrying the agent's OWN caps read from its `:identity` slice — that is
  # what holds the self-scoped `reconcile_cascade` + `Sandbox.update_config`
  # caps granted at create.
  @impl Ezagent.Lifecycle
  def handle_signal(@ce_reconcile_signal, ctx) do
    self_uri = Map.get(ctx, :self_uri)

    # `Cap.issue/3` recognizes the current target authority and runs K.grant
    # in-process, avoiding a synchronous self-call. Keep the bootstrap in this
    # Kind turn so authority DB access cannot outlive its sandbox owner; the two
    # absorb casts and the reconcile cast retain mailbox order.
    :ok = issue_self_caps_and_reconcile(self_uri)
    {:ok, []}
  end

  def handle_signal(_other, _ctx), do: :ignore

  defp issue_self_caps_and_reconcile(%URI{} = self_uri) do
    admin = Ezagent.URI.user(:system, :admin)

    reconcile_requested =
      Ezagent.Capability.cap(
        :agent,
        __MODULE__,
        :reconcile_cascade,
        Ezagent.URI.instance(self_uri),
        Ezagent.Capability.workspace_of(self_uri)
      )

    update_requested =
      Ezagent.Capability.cap(
        :agent,
        Ezagent.ActionSet.Sandbox,
        :update_config,
        Ezagent.URI.instance(self_uri),
        Ezagent.Capability.workspace_of(self_uri)
      )

    with {:ok, reconcile_cap} <-
           Ezagent.Cap.issue({:admin, admin}, self_uri, reconcile_requested),
         {:ok, update_cap} <-
           Ezagent.Cap.issue({:admin, admin}, self_uri, update_requested) do
      :ok = Ezagent.Identity.absorb_cap(self_uri, reconcile_cap)
      :ok = Ezagent.Identity.absorb_cap(self_uri, update_cap)

      self_uri
      |> Ezagent.Cmd.new(
        :reconcile_cascade,
        %{},
        %{
          caller: self_uri,
          authenticated_principal: self_uri,
          caps: MapSet.new([reconcile_cap, update_cap]),
          reply: :ignore
        }
      )
      |> Ezagent.Router.dispatch()
    end
  end

  # ---- STEP 1 — durable apply (manager-authorized) -------------------------
  #
  # Ported from `Ezagent.ActionSet.ConfigUpdate.handle_apply_delta` (#607
  # object-keyed ordering) MINUS (a) the subject-authority confused-deputy
  # predicate (the manage-cap gate + self-subject replace it) and (b) the
  # `repoint_agent_layer/2` cross-entity write (step 2 = the deferred
  # sandbox.update_config self-dispatch replaces it).
  #
  # The delta is carried in the dispatch ARGS (the agent has no `:turns`
  # slice — only the Session does). `turn_id` is the idempotency marker
  # stamped on the ConfigObject (`source_turn_id`).
  @spec handle_apply_config_delta(map(), map()) :: {:ok, map(), [term()]} | {:error, term()}
  def handle_apply_config_delta(%{turn_id: turn_id} = args, ctx) do
    # RESERVED-PREFIX GUARD — `cr-stage:`/`cr-publish:` are CR-owned
    # `source_turn_id` namespaces. Reject a caller-supplied reserved turn_id on
    # the NORMAL apply path BEFORE the `object_for_turn` idempotency early-return,
    # so a caller cannot spoof a same-turn no-op with a `cr-stage:` marker
    # (SPEC §4.2.1). Loud, not a silent no-op.
    if ConfigStore.reserved_turn_prefix?(turn_id) do
      {:error, {:reserved_turn_id_prefix, turn_id}}
    else
      do_handle_apply_config_delta(args, turn_id, ctx)
    end
  end

  defp do_handle_apply_config_delta(args, turn_id, ctx) do
    with raw_attrs <- attrs_from_args(args, turn_id, ctx),
         {:ok, attrs} <- validate_and_normalize(raw_attrs),
         # CE-1 — the agent applies config to ITSELF only. The dispatch is
         # gated by the TARGET agent's manage-cap, but `subject_uri`/
         # `workspace_uri` are caller-supplied; an unbound subject lets a
         # caller managing agent A dispatch to A with subject=agent B and
         # mutate B (cross-agent confused-deputy). Bind both to `self_uri`
         # BEFORE any store write.
         {:ok, attrs} <- assert_subject_self(attrs, ctx) do
      # CE-2 (PR-7) — idempotency (SERIAL re-dispatch), OBJECT-EXISTENCE-keyed
      # to match `applied_for_turn?/1`: if an object stamped with this `turn_id`
      # already exists, this turn was ALREADY applied → RETURN that object's
      # HISTORICAL id (a string — contract `config_id: :string` satisfied)
      # without minting a new object / repointing. Object existence is
      # permanent (objects are append-only), so this covers BOTH the
      # CURRENT-turn redelivery AND a SUPERSEDED-turn redelivery (turn A after
      # turn B advanced the pointer off A) — the prior pointer-aware
      # `pointer_object_for_turn` mismatched and fell through to the unique
      # index + a `config_id: nil` no-op. Checked AFTER self-binding so the
      # lookup is scoped to self.
      #
      # ITEM 3 (PR-6/7) — the idempotent path emits the deferred
      # sandbox.update_config projection of the CURRENT pointer object (NOT the
      # redelivered, possibly-superseded turn's object), so a redelivery
      # self-heals the cache to the live config (B) and NEVER reverts it to a
      # superseded turn (A). If there is no current pointer object, emit none.
      case ConfigStore.object_for_turn(turn_id) do
        {:ok, existing_id} ->
          {:ok, %{config_id: existing_id, previous_config_id: nil},
           sandbox_refresh_current_pointer(ctx, attrs)}

        :none ->
          do_apply_config_delta(turn_id, attrs, ctx)
      end
    end
  end

  defp do_apply_config_delta(turn_id, attrs, ctx) do
    body =
      case Map.get(attrs, :replace_body) do
        %{} = replacement ->
          replacement

        nil ->
          ConfigStore.merge_delta(
            attrs.layer,
            attrs.workspace_uri,
            attrs.subject_uri,
            attrs.key,
            attrs.patch
          )
      end

    # CE-3 — write the immutable object AND advance the pointer in ONE
    # transaction (`write_and_point/1`). Atomic write = no orphan object, so
    # the object-existence `applied_for_turn?` is sound.
    case ConfigStore.write_and_point(Map.put(attrs, :body, body)) do
      {:ok, %{config_id: config_id, previous_config_id: previous}} ->
        applied = ctx.read.(:applied, %{})
        reply = %{config_id: config_id, previous_config_id: previous}

        {:ok, reply,
         [{:set, :applied, Map.put(applied, turn_id, reply)}] ++
           sandbox_write_effects(ctx, attrs, config_id)}

      # CE-2 — CONCURRENT duplicate dispatch: another caller for the SAME turn
      # won the race and the unique index
      # (`socialware_config_objects_unique_source_turn`) rejected this insert
      # (surfaced as a changeset error, not a raw raise). Treat the collision
      # as "already applied": re-read the existing object and return it
      # idempotently (refreshing the sandbox cache too), never crash.
      {:error, %Ecto.Changeset{} = changeset} ->
        if source_turn_conflict?(changeset),
          do: idempotent_after_conflict(turn_id, attrs, ctx),
          else: {:error, changeset}
    end
  end

  # The unique index added in PR-6 surfaces as an error on `:source_turn_id`
  # in the ConfigObject changeset (see ConfigObject.changeset/1).
  defp source_turn_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:source_turn_id, {_msg, opts}} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end)
  end

  # The race-winner's object is now durable for this turn. Re-read it BY
  # OBJECT-EXISTENCE (PR-7) — the unique constraint that just fired proves an
  # object with this `source_turn_id` exists, so `object_for_turn/1` resolves
  # its id deterministically (no dependence on whether the winner's pointer is
  # the CURRENT pointer — a superseded turn's object still resolves). Return
  # the same idempotent result the serial early-return would have, with a
  # string `config_id` (NEVER nil) and the sandbox refreshed to the CURRENT
  # pointer so this loser heals its cache to the live config (not to a
  # superseded turn).
  defp idempotent_after_conflict(turn_id, attrs, ctx) do
    case ConfigStore.object_for_turn(turn_id) do
      {:ok, existing_id} ->
        {:ok, %{config_id: existing_id, previous_config_id: nil},
         sandbox_refresh_current_pointer(ctx, attrs)}

      :none ->
        # The unique constraint fired, so an object for this turn MUST exist;
        # not finding it would be a genuine invariant violation. Let it crash
        # (no silent `config_id: nil` no-op — that violated the contract).
        raise(
          "ConfigEvolve: source_turn unique conflict for turn_id=#{inspect(turn_id)} " <>
            "but object_for_turn/1 found no object (invariant violation)"
        )
    end
  end

  # CE-1 — reject any caller-supplied `subject_uri`/`workspace_uri` that does
  # not name THIS agent (or derive them from self when omitted). The agent may
  # only ever apply config to itself.
  defp assert_subject_self(attrs, ctx) do
    self_uri = ctx.self_uri
    self_workspace = Ezagent.URI.workspace_of(self_uri)

    cond do
      not same_uri?(attrs.subject_uri, self_uri) -> {:error, :subject_not_self}
      not same_uri?(attrs.workspace_uri, self_workspace) -> {:error, :subject_not_self}
      true -> {:ok, %{attrs | subject_uri: self_uri, workspace_uri: self_workspace}}
    end
  end

  defp same_uri?(a, b), do: uri_string(a) == uri_string(b)

  defp uri_string(%URI{} = uri), do: URI.to_string(uri)
  defp uri_string(other), do: other

  # ---- STEP 1 (rollback/advance) — `repoint_config` ------------------------
  #
  # Ported from `ConfigUpdate.handle_repoint` MINUS the subject-authority
  # predicate + the cross-entity repoint. Validates the caller-supplied
  # `config_id` (must name an existing in-scope object) BEFORE any side
  # effect, then advances the pointer and emits the same deferred
  # sandbox.update_config projection.
  @spec handle_repoint_config(map(), map()) :: {:ok, map(), [term()]} | {:error, term()}
  def handle_repoint_config(args, ctx) do
    raw_attrs = %{
      layer: Map.fetch!(args, :layer),
      workspace_uri: Map.fetch!(args, :workspace_uri),
      subject_uri: Map.fetch!(args, :subject_uri),
      key: Map.fetch!(args, :key),
      config_id: Map.fetch!(args, :config_id),
      actor_uri: ctx.caller,
      source_turn_id: "repoint:#{URI.to_string(ctx.self_uri)}"
    }

    with {:ok, attrs} <- validate_and_normalize(raw_attrs),
         # CE-1 — repoint, like apply, may only ever target THIS agent's own
         # config pointer; bind/reject the caller-supplied subject/workspace.
         {:ok, attrs} <- assert_subject_self(attrs, ctx),
         {:ok, _object} <- ConfigStore.fetch_matching_object(attrs),
         {:ok, %{previous_config_id: previous}} <- ConfigStore.put_pointer(attrs) do
      {:ok, %{config_id: attrs.config_id, previous_config_id: previous},
       sandbox_write_effects(ctx, attrs, attrs.config_id)}
    end
  end

  # ---- READ — manage-cap-gated config cascade read -------------------------
  #
  # The agent reads ITS OWN config cascade. The dispatch is authorized by the
  # agent's manage-cap (step-5.5, on the caller's real caps) — symmetric with
  # the writes — so a caller without the manage-cap gets `{:error, :unauthorized}`
  # BEFORE this handler runs. The read subject is always `ctx.self_uri` (the
  # agent being read), never caller-supplied, so the gate is non-tautological:
  # the cap is checked against the AUTHENTICATED caller, the data is scoped to
  # the dispatched-to agent. Builds the same cascade shape the console facade
  # exposes (`Ezagent.Agent.Config`).
  @spec handle_read_cascade(map(), map()) :: {:ok, map(), [term()]}
  def handle_read_cascade(args, ctx) do
    cascade = build_cascade(ctx.self_uri, Map.get(args, :keys))
    {:ok, %{cascade: cascade}, []}
  end

  @doc """
  Build the editable config cascade for `agent_uri` PURELY from the durable
  `ConfigStore` (DB only) — NO process, NO Kind activation, NO ctx/live slice.

  This is the same shape `handle_read_cascade/2` returns (and the console facade
  `Ezagent.Agent.Config.read_cascade/4` exposes). It is exposed as a public pure
  function so the facade can read the cascade DIRECTLY without dispatching the
  `read_cascade` action (which would force-activate a cold agent — the FP5 S5
  `:activate_timeout` bug, #115). The facade preserves the manage-cap gate
  itself BEFORE calling this; this function performs NO authorization (it is a
  pure projection of durable rows). `keys` is `nil` (read all subject keys) or a
  list of key strings to filter.
  """
  @spec build_cascade(URI.t() | String.t(), [String.t()] | nil) :: map()
  def build_cascade(agent_uri, keys \\ nil) do
    agent_uri = normalize_agent_uri(agent_uri)
    workspace_uri = Ezagent.URI.workspace_of(agent_uri)
    resolved_keys = keys_for(agent_uri, keys)

    %{
      agent_uri: URI.to_string(agent_uri),
      workspace_uri: URI.to_string(workspace_uri),
      default_key: @default_cascade_key,
      layer_order: @layer_order,
      keys: Enum.map(resolved_keys, &key_state(agent_uri, workspace_uri, &1))
    }
  end

  defp normalize_agent_uri(%URI{} = uri), do: uri
  defp normalize_agent_uri(uri) when is_binary(uri), do: Ezagent.URI.new!(uri)

  # The cascade-shape readers (ported from the facade — the facade no longer
  # reads ConfigStore directly; it dispatches THIS action so the read is gated).
  defp keys_for(agent_uri, requested) do
    requested =
      case requested do
        keys when is_list(keys) -> Enum.map(keys, &to_string/1)
        _ -> ConfigStore.list_keys_for_subject(agent_uri)
      end

    requested
    |> Kernel.++([@default_cascade_key])
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp key_state(agent_uri, workspace_uri, key) do
    layers = ConfigStore.layer_objects_for_key(agent_uri, key)
    layer_states = Map.new(@layer_order, &{&1, layer_state(workspace_uri, &1, layers[&1])})

    %{
      key: key,
      effective_body: effective_body(layer_states),
      editable: true,
      editable_layer: @editable_layer,
      layers: layer_states
    }
  end

  defp layer_state(_workspace_uri, _layer, nil), do: nil

  defp layer_state(workspace_uri, layer, %{pointer: pointer, object: object}) do
    %{
      layer: layer,
      config_id: object.id,
      previous_config_id: pointer.previous_config_id,
      object_uri: workspace_uri |> ConfigProjection.object_uri(object.id) |> URI.to_string(),
      body: object.body || %{},
      source_turn_id: object.source_turn_id,
      updated_at: datetime(pointer.updated_at)
    }
  end

  defp effective_body(layer_states) do
    Enum.reduce(@layer_order, %{}, fn layer, acc ->
      case layer_states[layer] do
        %{body: %{} = body} -> Map.merge(acc, body)
        _ -> acc
      end
    end)
  end

  defp datetime(nil), do: nil
  defp datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp datetime(other), do: to_string(other)

  # ---- reconcile_cascade — boot self-heal (full action ctx) ----------------
  #
  # Self-dispatched from `handle_signal/2` post-`:ready`. Compares the
  # ConfigStore current user-layer pointer to the Sandbox cache
  # (`cascade_resolution.user_layer_uri`) and emits the SAME
  # `Cmd(self, :update_config, rtd)` if they diverge. Reads the sandbox via
  # `ctx.siblings[:sandbox]` (the action-ctx sibling injection). A no-op
  # (or absent pointer / sandbox) returns `{reconciled: false}` with no
  # effects.
  @spec handle_reconcile_cascade(map(), map()) :: {:ok, map(), [term()]}
  def handle_reconcile_cascade(_args, ctx) do
    with {:ok, object_id} <- ConfigStore.current_user_object(ctx.self_uri, @default_cascade_key),
         sandbox when is_map(sandbox) <- sibling_sandbox(ctx),
         want <- object_layer_uri(ctx.self_uri, object_id),
         current <- current_user_layer_uri(sandbox),
         true <- current != want do
      {:ok, %{reconciled: true}, [{:dispatch, sandbox_write_cmd(ctx, sandbox, want)}]}
    else
      _ -> {:ok, %{reconciled: false}, []}
    end
  end

  # ---- step-2 effect builder (deferred sandbox.update_config self-dispatch) ----
  #
  # rev-4 H1: read the agent's OWN Sandbox cascade in-process (sibling),
  # compute the refreshed respawn_template_data with the new object's URI as
  # `user_layer_uri`, and emit ONE `{:dispatch_after_commit, Cmd(self,
  # :update_config, rtd)}`. The dispatched action IS `:update_config` → gated by
  # the agent's self-scoped `cap(:agent, Sandbox, :update_config)`. As a
  # post-commit cast it never deadlocks; on a missing self-cap the write
  # fails (logged, non-fatal — the boot reconcile heals).
  #
  # If the agent has no sandbox / no cascade_resolution yet, there is no
  # cache to refresh — return no effect (the durable ConfigStore write
  # already succeeded; the spawn read path resolves the object directly).
  defp sandbox_write_effects(ctx, attrs, object_id) do
    case sibling_sandbox(ctx) do
      sandbox when is_map(sandbox) ->
        case fetch_resolution(sandbox) do
          {:ok, _rtd, _resolution} ->
            object_uri = object_layer_uri(attrs.subject_uri, object_id)
            [{:dispatch_after_commit, sandbox_write_cmd(ctx, sandbox, object_uri)}]

          :error ->
            []
        end

      _ ->
        []
    end
  end

  @doc """
  CR-governance reuse seam — emit the deferred `sandbox.update_config` self-dispatch
  that re-materializes the agent's resolved soul into its config_dir, projecting
  the CURRENT durable pointer for `(subject_uri, key)`.

  `ConfigGovernance.publish_cr` lives on the SAME Agent Kind but is a DIFFERENT
  module, so it cannot reach this behavior's `defp` effect builder. This is the
  ONE public seam it calls — AFTER the publish Multi has flipped the pointer(s),
  so `current_user_object/2` resolves to the just-published object and the
  emitted effect materializes the published config (SPEC §4.3.5 "fire the
  EXISTING sandbox materialization — no new materialization"). It carries the
  agent's OWN caps (`:identity` sibling), exactly like the apply/repoint paths.

  Expects `ctx` to be a genuine agent ACTION ctx (declares
  `reads_siblings([:sandbox, :identity])`); a no-op (empty effect list) if the
  agent has no sandbox / no cascade cache / no current pointer for the slot.
  """
  @spec sandbox_refresh_effects(map(), %{subject_uri: URI.t() | String.t(), key: String.t()}) ::
          [term()]
  def sandbox_refresh_effects(ctx, %{subject_uri: subject_uri, key: key}) do
    sandbox_refresh_current_pointer(ctx, %{subject_uri: subject_uri, key: key})
  end

  # PR-7 — idempotent-path sandbox refresh. A redelivered turn (current OR
  # superseded) minted NO new object; the cache must be refreshed to the
  # CURRENT pointer's object, NOT the redelivered turn's (a superseded turn's
  # object would REVERT the live config). Reads the durable current user-layer
  # pointer (`ConfigStore.current_user_object`) and projects IT. If there is no
  # current pointer object (edge — nothing applied yet), or no sandbox/cascade
  # cache, emit no effect.
  defp sandbox_refresh_current_pointer(ctx, attrs) do
    with sandbox when is_map(sandbox) <- sibling_sandbox(ctx),
         {:ok, _rtd, _resolution} <- fetch_resolution(sandbox),
         {:ok, current_id} <- ConfigStore.current_user_object(attrs.subject_uri, attrs.key) do
      object_uri = object_layer_uri(attrs.subject_uri, current_id)
      [{:dispatch_after_commit, sandbox_write_cmd(ctx, sandbox, object_uri)}]
    else
      _ -> []
    end
  end

  # Build the `sandbox.update_config` self-dispatch Cmd that refreshes the
  # cascade `user_layer_uri` to `object_uri`. Preserves config_dir_path +
  # template_class (update_config overwrites all three fields); only
  # respawn_template_data changes.
  defp sandbox_write_cmd(ctx, sandbox, object_uri) when is_binary(object_uri) do
    rtd = Map.get(sandbox, :respawn_template_data)
    resolution = current_resolution(rtd) || %{}
    updated_resolution = put_user_layer(resolution, object_uri)
    updated_rtd = put_resolution(rtd || %{}, updated_resolution)

    Ezagent.Cmd.new(
      ctx.self_uri,
      :update_config,
      %{
        config_dir_path: Map.get(sandbox, :config_dir_path),
        template_class: Map.get(sandbox, :template_class),
        respawn_template_data: updated_rtd
      },
      # The write is the AGENT acting on ITSELF — authorized by its OWN
      # self-scoped `cap(:agent, Sandbox, :update_config)`, NOT the step-1
      # caller's (the manager holds only the manage-cap). Carry the agent's
      # own caps from its `:identity` sibling slice. If the self-cap is
      # absent the write is denied (logged, non-fatal — boot reconcile
      # heals).
      %{
        caller: ctx.self_uri,
        authenticated_principal: ctx.self_uri,
        caps: MapSet.union(agent_own_caps(ctx), inline_caps(ctx)),
        reply: :ignore
      }
    )
  end

  # ---- sandbox sibling read helpers ----------------------------------------

  # `ctx.siblings[:sandbox]` is the sandbox's persistent `:state` map
  # (`%{config_dir_path:, template_class:, respawn_template_data:, …}`,
  # atom keys), normalized from the two-container slice by the runtime.
  defp sibling_sandbox(ctx) do
    ctx
    |> Map.get(:siblings, %{})
    |> Map.get(:sandbox)
  end

  defp fetch_resolution(sandbox) do
    case current_resolution(Map.get(sandbox, :respawn_template_data)) do
      %{} = res -> {:ok, Map.get(sandbox, :respawn_template_data), res}
      _ -> :error
    end
  end

  defp current_resolution(%{} = rtd), do: rtd["cascade_resolution"] || rtd[:cascade_resolution]
  defp current_resolution(_), do: nil

  defp current_user_layer_uri(sandbox) do
    case current_resolution(Map.get(sandbox, :respawn_template_data)) do
      %{} = res -> res["user_layer_uri"] || res[:user_layer_uri]
      _ -> nil
    end
  end

  # Ported from `Ezagent.Socialware.CascadeRepoint.put_user_layer/2`.
  defp put_user_layer(resolution, object_uri) when is_binary(object_uri) do
    key =
      if Map.has_key?(resolution, :user_layer_uri), do: :user_layer_uri, else: "user_layer_uri"

    Map.put(resolution, key, object_uri)
  end

  # Ported from `Ezagent.Socialware.CascadeRepoint.put_resolution/2`.
  defp put_resolution(rtd, resolution) do
    key =
      if Map.has_key?(rtd, :cascade_resolution),
        do: :cascade_resolution,
        else: "cascade_resolution"

    Map.put(rtd, key, resolution)
  end

  defp object_layer_uri(subject_uri, object_id) do
    subject_uri
    |> Ezagent.URI.workspace_of()
    |> ConfigProjection.object_uri(object_id)
    |> URI.to_string()
  end

  # ---- own-caps reads ------------------------------------------------------
  #
  # The agent's OWN caps live in its `:identity` slice on the same Kind. Two
  # surfaces expose it depending on which hook is running:
  #
  #   * ACTION ctx (`handle_apply_config_delta` / `handle_reconcile_cascade`)
  #     — the declared `:identity` sibling, `ctx.siblings[:identity][:caps]`.
  #     Used to authorize the deferred `sandbox.update_config` self-dispatch.
  #   * SIGNAL ctx (`handle_signal/2`) — there is NO sibling injection; the
  #     macro surfaces all slices read-only via `ctx.slice_state`. Used to
  #     authorize the `reconcile_cascade` self-dispatch.

  defp agent_own_caps(ctx) do
    ctx
    |> Map.get(:siblings, %{})
    |> Map.get(:identity, %{})
    |> caps_of_identity()
  end

  defp inline_caps(ctx) do
    case Map.get(ctx, :caps) do
      %MapSet{} = caps -> caps
      caps when is_list(caps) -> MapSet.new(caps)
      _ -> MapSet.new()
    end
  end

  defp caps_of_identity(identity) when is_map(identity) do
    case Map.get(identity, :caps) do
      %MapSet{} = set -> set
      list when is_list(list) -> MapSet.new(list)
      _ -> MapSet.new()
    end
  end

  defp caps_of_identity(_), do: MapSet.new()

  # ---- delta validation/normalization --------------------------------------
  #
  # Ported from `ConfigUpdate.validate_and_normalize/2` MINUS the
  # confused-deputy authority predicate (`assert_workspace` /
  # `assert_session_manages`): the agent IS the subject (there is no deputy),
  # and the manage-cap gate proved the caller may evolve THIS agent. We keep
  # the field validation/normalization (the #607 round-5 single-upfront
  # chokepoint) so an invalid layer/key/uri is rejected loud BEFORE any
  # store write.
  @spec validate_and_normalize(map()) :: {:ok, map()} | {:error, term()}
  defp validate_and_normalize(attrs) do
    with {:ok, layer} <- ConfigStore.normalize_layer(attrs.layer),
         {:ok, workspace_uri} <- ConfigStore.normalize_uri(attrs.workspace_uri, :workspace_uri),
         {:ok, subject_uri} <- ConfigStore.normalize_uri(attrs.subject_uri, :subject_uri),
         {:ok, key} <- ConfigStore.validate_key(attrs.key),
         :ok <- validate_replace_body(Map.get(attrs, :replace_body)) do
      {:ok,
       attrs
       |> Map.put(:layer, layer)
       |> Map.put(:workspace_uri, workspace_uri)
       |> Map.put(:subject_uri, subject_uri)
       |> Map.put(:key, key)}
    end
  end

  defp validate_replace_body(nil), do: :ok
  defp validate_replace_body(body) when is_map(body), do: :ok

  defp validate_replace_body(other),
    do: {:error, {:invalid_replace_body, %{got: inspect(other)}}}

  # The delta is carried in the dispatch ARGS (the agent has no turn slice).
  # `subject_uri` defaults to the agent itself (it IS the subject); a caller
  # may still pass it explicitly (PR-3 Turn rewire forwards the settled
  # delta's fields). The actor is the manage-cap-holding caller.
  defp attrs_from_args(args, turn_id, ctx) do
    %{
      layer: Map.get(args, :layer) || :user,
      workspace_uri: Map.get(args, :workspace_uri) || Ezagent.URI.workspace_of(ctx.self_uri),
      subject_uri: Map.get(args, :subject_uri) || ctx.self_uri,
      key: Map.get(args, :key) || @default_cascade_key,
      patch: Map.get(args, :patch) || %{},
      replace_body: Map.get(args, :replace_body),
      actor_uri: ctx.caller,
      source_turn_id: turn_id
    }
  end
end
