defmodule Ezagent.Behavior.ConfigEvolve do
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
    `{:dispatch_after_commit, Cmd(self, :write_path, rtd)}` — the deferred
    self-dispatch to **`sandbox.write_path`** (rev-4 H1: the dispatched
    action IS `:write_path`, matching the agent's self-scoped
    `cap(:agent, Sandbox, :write_path)` — there is no
    `project_cascade_to_sandbox` action whose action axis the runtime would
    overwrite).

  - **STEP 2** is therefore NOT a separate ConfigEvolve action — it is the
    deferred `sandbox.write_path` self-dispatch step 1 emits. Demoting the
    Sandbox pointer from source to spawn-cache keeps the spawn read path
    untouched.

  ## Boot reconciliation (crash-window self-heal)

  If the agent crashes between step 1's commit and the deferred
  `write_path` running, the Sandbox cache is stale. `activate/2` cannot emit
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
  the Sandbox cache and emits the SAME `Cmd(self, :write_path, rtd)` if they
  diverge. This closes the window in the agent's own domain (no
  `core→ConfigStore` dependency).

  ## Authority (§4)

  `apply_config_delta` / `repoint_config` → the agent's manage-cap (whoever
  manages the agent may evolve it; the membership-OR-lineage approximation
  is retired). `reconcile_cascade` → the agent's self-scoped
  `cap(:agent, ConfigEvolve, :reconcile_cascade)`. The emitted
  `sandbox.write_path` → the agent's self-scoped
  `cap(:agent, Sandbox, :write_path)`. The confused-deputy authority guard
  (`subject_uri` belongs to a manageable agent) is GONE because the agent
  IS the subject — there is no deputy.

  Owns the `:config_evolve` slice (`%{applied: %{turn_id => reply}}` —
  applied-turn idempotency markers; the durable config-version state lives
  in `ConfigStore`).
  """

  use Ezagent.Lifecycle

  require Logger

  alias Ezagent.Socialware.{ConfigProjection, ConfigStore}

  # rev-4: step 1 / reconcile read the agent's OWN Sandbox cascade in-process
  # (the genuine ApiKeys in-process read precedent) to compute the refreshed
  # respawn_template_data. Surfaced as `ctx.siblings[:sandbox]` on action ctx.
  #
  # `:identity` is ALSO declared because the deferred `sandbox.write_path`
  # self-dispatch must carry the AGENT's OWN caps (its self-scoped
  # `cap(:agent, Sandbox, :write_path)`), NOT the step-1 caller's (the
  # manager holds only the manage-cap). The agent's caps live in its own
  # `:identity` slice on the same Kind — read in-process via
  # `ctx.siblings[:identity][:caps]`.
  reads_siblings([:sandbox, :identity])

  # The cascade key the user layer is stored under. The delta carries its own
  # `key`; reconciliation needs a default to read the current pointer.
  @default_cascade_key "advisor.behavior"

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
      patch: {:option, :map}
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

  action(:reconcile_cascade,
    args: %{},
    returns: %{reconciled: :boolean},
    caps: [:reconcile_cascade],
    modes: [:cast],
    description:
      "Reconcile the agent's Sandbox cache against the durable ConfigStore " <>
        "pointer (boot self-heal); emits sandbox.write_path if divergent"
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
  # The sandbox write step 1 / reconcile emit is a Cmd(self, :write_path, …),
  # gated by cap(:agent, Sandbox, :write_path) — the agent holds it over
  # itself (granted at create, see Ezagent.Behavior.Identity.create/1).
  def required_caps do
    %{
      apply_config_delta: Ezagent.Capability.cap(:agent, Ezagent.Behavior.Manage, :any),
      repoint_config: Ezagent.Capability.cap(:agent, Ezagent.Behavior.Manage, :any),
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
  # what holds the self-scoped `reconcile_cascade` + `Sandbox.write_path`
  # caps granted at create.
  @impl Ezagent.Lifecycle
  def handle_signal(@ce_reconcile_signal, ctx) do
    self_uri = Map.get(ctx, :self_uri)
    caps = own_caps(ctx)

    cmd =
      Ezagent.Cmd.new(
        self_uri,
        :reconcile_cascade,
        %{},
        %{caller: self_uri, caps: caps, reply: :ignore}
      )

    {:ok, [{:dispatch, cmd}]}
  end

  def handle_signal(_other, _ctx), do: :ignore

  # ---- STEP 1 — durable apply (manager-authorized) -------------------------
  #
  # Ported from `Ezagent.Behavior.ConfigUpdate.handle_apply_delta` (#607
  # object-keyed ordering) MINUS (a) the subject-authority confused-deputy
  # predicate (the manage-cap gate + self-subject replace it) and (b) the
  # `repoint_agent_layer/2` cross-entity write (step 2 = the deferred
  # sandbox.write_path self-dispatch replaces it).
  #
  # The delta is carried in the dispatch ARGS (the agent has no `:turns`
  # slice — only the Session does). `turn_id` is the idempotency marker
  # stamped on the ConfigObject (`source_turn_id`).
  @spec handle_apply_config_delta(map(), map()) :: {:ok, map(), [term()]} | {:error, term()}
  def handle_apply_config_delta(%{turn_id: turn_id} = args, ctx) do
    with raw_attrs <- attrs_from_args(args, turn_id, ctx),
         {:ok, attrs} <- validate_and_normalize(raw_attrs),
         body <-
           ConfigStore.merge_delta(
             attrs.layer,
             attrs.workspace_uri,
             attrs.subject_uri,
             attrs.key,
             attrs.patch
           ),
         {:ok, object} <- ConfigStore.write_config(Map.put(attrs, :body, body)),
         {:ok, %{previous_config_id: previous}} <-
           ConfigStore.put_pointer(Map.put(attrs, :config_id, object.id)) do
      applied = ctx.read.(:applied, %{})
      reply = %{config_id: object.id, previous_config_id: previous}

      {:ok, reply,
       [{:set, :applied, Map.put(applied, turn_id, reply)}] ++
         sandbox_write_effects(ctx, attrs, object.id)}
    end
  end

  # ---- STEP 1 (rollback/advance) — `repoint_config` ------------------------
  #
  # Ported from `ConfigUpdate.handle_repoint` MINUS the subject-authority
  # predicate + the cross-entity repoint. Validates the caller-supplied
  # `config_id` (must name an existing in-scope object) BEFORE any side
  # effect, then advances the pointer and emits the same deferred
  # sandbox.write_path projection.
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
         {:ok, _object} <- ConfigStore.fetch_matching_object(attrs),
         {:ok, %{previous_config_id: previous}} <- ConfigStore.put_pointer(attrs) do
      {:ok, %{config_id: attrs.config_id, previous_config_id: previous},
       sandbox_write_effects(ctx, attrs, attrs.config_id)}
    end
  end

  # ---- reconcile_cascade — boot self-heal (full action ctx) ----------------
  #
  # Self-dispatched from `handle_signal/2` post-`:ready`. Compares the
  # ConfigStore current user-layer pointer to the Sandbox cache
  # (`cascade_resolution.user_layer_uri`) and emits the SAME
  # `Cmd(self, :write_path, rtd)` if they diverge. Reads the sandbox via
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

  # ---- step-2 effect builder (deferred sandbox.write_path self-dispatch) ----
  #
  # rev-4 H1: read the agent's OWN Sandbox cascade in-process (sibling),
  # compute the refreshed respawn_template_data with the new object's URI as
  # `user_layer_uri`, and emit ONE `{:dispatch_after_commit, Cmd(self,
  # :write_path, rtd)}`. The dispatched action IS `:write_path` → gated by
  # the agent's self-scoped `cap(:agent, Sandbox, :write_path)`. As a
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

  # Build the `sandbox.write_path` self-dispatch Cmd that refreshes the
  # cascade `user_layer_uri` to `object_uri`. Preserves config_dir_path +
  # template_class (write_path overwrites all three fields); only
  # respawn_template_data changes.
  defp sandbox_write_cmd(ctx, sandbox, object_uri) when is_binary(object_uri) do
    rtd = Map.get(sandbox, :respawn_template_data)
    resolution = current_resolution(rtd) || %{}
    updated_resolution = put_user_layer(resolution, object_uri)
    updated_rtd = put_resolution(rtd || %{}, updated_resolution)

    Ezagent.Cmd.new(
      ctx.self_uri,
      :write_path,
      %{
        config_dir_path: Map.get(sandbox, :config_dir_path),
        template_class: Map.get(sandbox, :template_class),
        respawn_template_data: updated_rtd
      },
      # The write is the AGENT acting on ITSELF — authorized by its OWN
      # self-scoped `cap(:agent, Sandbox, :write_path)`, NOT the step-1
      # caller's (the manager holds only the manage-cap). Carry the agent's
      # own caps from its `:identity` sibling slice. If the self-cap is
      # absent the write is denied (logged, non-fatal — boot reconcile
      # heals).
      %{caller: ctx.self_uri, caps: agent_own_caps(ctx), reply: :ignore}
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
  #     Used to authorize the deferred `sandbox.write_path` self-dispatch.
  #   * SIGNAL ctx (`handle_signal/2`) — there is NO sibling injection; the
  #     macro surfaces all slices read-only via `ctx.slice_state`. Used to
  #     authorize the `reconcile_cascade` self-dispatch.

  defp agent_own_caps(ctx) do
    ctx
    |> Map.get(:siblings, %{})
    |> Map.get(:identity, %{})
    |> caps_of_identity()
  end

  defp own_caps(ctx) do
    ctx
    |> Map.get(:slice_state, %{})
    |> Map.get(:identity, %{})
    |> normalize_slice()
    |> caps_of_identity()
  end

  defp caps_of_identity(identity) when is_map(identity) do
    case Map.get(identity, :caps) do
      %MapSet{} = set -> set
      list when is_list(list) -> MapSet.new(list)
      _ -> MapSet.new()
    end
  end

  defp caps_of_identity(_), do: MapSet.new()

  defp normalize_slice(%{state: st, transients: _}) when is_map(st), do: st
  defp normalize_slice(other) when is_map(other), do: other
  defp normalize_slice(_), do: %{}

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
         {:ok, key} <- ConfigStore.validate_key(attrs.key) do
      {:ok,
       attrs
       |> Map.put(:layer, layer)
       |> Map.put(:workspace_uri, workspace_uri)
       |> Map.put(:subject_uri, subject_uri)
       |> Map.put(:key, key)}
    end
  end

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
      actor_uri: ctx.caller,
      source_turn_id: turn_id
    }
  end
end
