defmodule Ezagent.ActionSet.ConfigGovernance do
  @moduledoc """
  Minimal CR (change-request) config governance on the Agent Kind — a Lifecycle
  sibling to `Ezagent.ActionSet.ConfigEvolve` (SPEC
  `docs/together/2026-06-26/specs/cr-config-governance.md`, rev 3).

  A thin EXTENSION of the shipped `ConfigStore` + sandbox-materialization
  primitives. It adds draft aggregation (stage N inert objects under one CR) +
  publish (flip the pointer(s), which fires the EXISTING sandbox materialization)
  + rollback (existing `repoint_config`). Preview is a plain `render_soul/1` diff.
  No lint, no review pipeline, no two-person rule, no new preview/sandbox system.

  ## Why a behavior (not just a facade `if`)

  CR actions are routed through dispatch so the standard step-5.5 cap gate
  authorizes them — the gate is STRUCTURAL, not a hand-rolled check (mirroring
  how `ConfigEvolve.read_cascade` was routed through dispatch). The cap is the
  agent's MANAGE cap (lead decision OQ-4) — the SAME cap `apply_config_delta`
  uses. Whoever may edit config may open / stage / publish / reject / rollback a
  CR. No separate publish or reviewer cap.

  ## CE-1 self-binding inherited

  publish / rollback (and stage / open) are dispatched TO the subject agent and
  the stored CR `subject_uri` MUST equal `self_uri` before any pointer flip — a
  caller managing agent A cannot publish a CR whose pointers target agent B.

  ## Publish materialization (codex must-fix #3)

  `publish_cr` runs in a genuine agent ACTION ctx (`reads_siblings([:sandbox,
  :identity])`) so — AFTER the publish Multi flips the pointer(s) — it can emit
  the deferred `sandbox.update_config` self-dispatch via the public reuse seam
  `ConfigEvolve.sandbox_refresh_effects/2`, which projects the CURRENT (now
  published) pointer object into the config_dir. The pointer flip ALONE does NOT
  materialize — the effect emission is mandatory.

  Owns NO persistent state — the CR/item rows live in `Ezagent.ConfigGovernance.Store`.
  """

  use Ezagent.Lifecycle

  alias Ezagent.ActionSet.ConfigEvolve
  alias Ezagent.ConfigGovernance
  alias Ezagent.ConfigGovernance.Agent, as: AgentPolicy
  alias Ezagent.ConfigGovernance.Store
  alias Ezagent.Socialware.ConfigProjection

  # Read the agent's OWN Sandbox + Identity siblings — IDENTICAL to ConfigEvolve.
  # `:sandbox` so publish/rollback can compute the deferred materialization
  # effect; `:identity` so that effect carries the AGENT's OWN caps (its
  # self-scoped `cap(:agent, Sandbox, :update_config)`), not the manage-cap caller's.
  reads_siblings([:sandbox, :identity])

  @default_cascade_key "agent.soul"

  # ---- action declarations -------------------------------------------------

  action(:open_cr,
    args: %{title: {:option, :string}, note: {:option, :string}},
    returns: %{cr_id: :string, status: :string},
    caps: [:open_cr],
    modes: [:call],
    description: "Open a CR for THIS agent (manage-cap gated; v1 agent-subject only)"
  )

  action(:stage_item,
    args: %{
      change_request_id: :string,
      layer: {:option, :atom},
      key: {:option, :string},
      patch: {:option, :map},
      replace_body: {:option, :map}
    },
    returns: %{item_id: :string, staged_object_id: :string},
    caps: [:stage_item],
    modes: [:call],
    description: "Stage an inert config object under an open CR (no pointer moved)"
  )

  action(:unstage_item,
    args: %{change_request_id: :string, layer: {:option, :atom}, key: {:option, :string}},
    returns: %{unstaged: :boolean},
    caps: [:unstage_item],
    modes: [:call],
    description: "Remove a staged slot from an open CR"
  )

  action(:preview_cr,
    args: %{change_request_id: :string},
    returns: %{items: {:list, :map}},
    caps: [:preview_cr],
    modes: [:call],
    description: "Plain render_soul/1 diff of proposed vs current (no checks)"
  )

  action(:publish_cr,
    args: %{change_request_id: :string},
    returns: %{cr_id: :string, status: :string, published_turn_id: :string},
    caps: [:publish_cr],
    modes: [:call],
    description: "Flip the staged pointer(s) in one Multi + fire sandbox materialization"
  )

  action(:reject_cr,
    args: %{change_request_id: :string},
    returns: %{cr_id: :string, status: :string},
    caps: [:reject_cr],
    modes: [:call],
    description: "Reject an open CR (nothing was ever pointed-to)"
  )

  action(:rollback_cr,
    args: %{change_request_id: :string},
    returns: %{cr_id: :string, status: :string},
    caps: [:rollback_cr],
    modes: [:call],
    description: "Roll back a published CR via the existing repoint_config"
  )

  # codex must-fix #1 — each CR action's declared cap is the agent's MANAGE cap
  # with ACTION == the dispatched action (the runtime overwrites the needed-cap
  # action with the dispatched action, so the held `cap(:agent, Manage, :any,
  # instance: agent)` with action :any matches any of these). publish REUSES the
  # agent's MANAGE cap (lead decision OQ-4) — no separate publish/reviewer cap.
  def required_caps do
    manage = Ezagent.Capability.cap(:agent, Ezagent.ActionSet.Manage, :any)

    %{
      open_cr: manage,
      stage_item: manage,
      unstage_item: manage,
      preview_cr: manage,
      publish_cr: manage,
      reject_cr: manage,
      rollback_cr: manage
    }
  end

  # The agent owns its own CR-governance state (none persistent here; the data
  # lives in Store). Mirrors ConfigEvolve.data_owner/1.
  @spec data_owner(URI.t() | :any | term()) :: URI.t() | :any | :no_owner
  def data_owner(%URI{scheme: "entity"} = agent_uri), do: Ezagent.URI.instance(agent_uri)
  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner

  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{}}

  # ---- handlers ------------------------------------------------------------

  @doc false
  @spec handle_open_cr(map(), map()) :: {:ok, map(), [term()]} | {:error, term()}
  def handle_open_cr(args, ctx) do
    self_uri = ctx.self_uri
    workspace = Ezagent.URI.workspace_of(self_uri)

    # v1 agent-subject only — the subject IS this agent (self-bound); a non-agent
    # subject would have no agent handler to dispatch publish/rollback to.
    with :ok <- AgentPolicy.assert_agent_subject(self_uri),
         {:ok, cr} <-
           Store.open(%{
             workspace_uri: workspace,
             subject_uri: self_uri,
             opened_by: ctx.caller,
             title: Map.get(args, :title),
             note: Map.get(args, :note)
           }) do
      {:ok, %{cr_id: cr.id, status: cr.status}, []}
    end
  end

  @doc false
  @spec handle_stage_item(map(), map()) :: {:ok, map(), [term()]} | {:error, term()}
  def handle_stage_item(args, ctx) do
    with {:ok, _cr} <- fetch_self_cr(args, ctx),
         {:ok, item} <-
           Store.stage_item(%{
             change_request_id: Map.fetch!(args, :change_request_id),
             layer: Map.get(args, :layer) || :user,
             key: Map.get(args, :key) || @default_cascade_key,
             patch: Map.get(args, :patch),
             replace_body: Map.get(args, :replace_body),
             actor_uri: ctx.caller
           }) do
      {:ok, %{item_id: item.id, staged_object_id: item.staged_object_id}, []}
    end
  end

  @doc false
  @spec handle_unstage_item(map(), map()) :: {:ok, map(), [term()]} | {:error, term()}
  def handle_unstage_item(args, ctx) do
    with {:ok, _cr} <- fetch_self_cr(args, ctx),
         {:ok, :unstaged} <-
           Store.unstage_item(%{
             change_request_id: Map.fetch!(args, :change_request_id),
             layer: Map.get(args, :layer) || :user,
             key: Map.get(args, :key) || @default_cascade_key
           }) do
      {:ok, %{unstaged: true}, []}
    end
  end

  @doc false
  @spec handle_preview_cr(map(), map()) :: {:ok, map(), [term()]} | {:error, term()}
  def handle_preview_cr(args, ctx) do
    with {:ok, _cr} <- fetch_self_cr(args, ctx),
         {:ok, diffs} <- Store.preview(Map.fetch!(args, :change_request_id)) do
      {:ok, %{items: Enum.map(diffs, &with_soul_diff/1)}, []}
    end
  end

  # codex must-fix #3 — publish in a real agent action ctx so the deferred
  # sandbox.update_config fires. The Multi flips the pointer(s); THEN we emit the
  # materialization effect (projecting the now-current published object).
  @doc false
  @spec handle_publish_cr(map(), map()) :: {:ok, map(), [term()]} | {:error, term()}
  def handle_publish_cr(args, ctx) do
    cr_id = Map.fetch!(args, :change_request_id)

    with {:ok, cr} <- fetch_self_cr(args, ctx),
         {:ok, %{cr: published, items: items}} <-
           Store.publish(%{change_request_id: cr_id, published_by: ctx.caller}) do
      {:ok,
       %{
         cr_id: published.id,
         status: published.status,
         published_turn_id: published.published_turn_id
       }, sandbox_effects_for_items(ctx, cr.subject_uri, items)}
    end
  end

  @doc false
  @spec handle_reject_cr(map(), map()) :: {:ok, map(), [term()]} | {:error, term()}
  def handle_reject_cr(args, ctx) do
    with {:ok, _cr} <- fetch_self_cr(args, ctx),
         {:ok, rejected} <- Store.reject(Map.fetch!(args, :change_request_id)) do
      {:ok, %{cr_id: rejected.id, status: rejected.status}, []}
    end
  end

  # rollback REUSES the existing repoint VERBATIM (SPEC §4.5) — for each
  # published item, dispatch the EXISTING `ConfigEvolve.handle_repoint_config/2`
  # aimed at the durable `published_prev_object_id` (NOT the live pointer's
  # previous_config_id, which the publish flip overwrote). That handler already
  # self-binds the subject (CE-1), validates the prior object
  # (`fetch_matching_object/1`), advances the pointer (`put_pointer`), AND emits
  # the step-2 sandbox refresh — so we reuse the whole repoint mechanism (no new
  # repoint, no duplicated scope guard, no separate materialization). A nil-prior
  # item (brand-new key at publish) leaves the new pointer in place (partial
  # rollback; SPEC §4.5 Q2 — no pointer-delete primitive).
  #
  # NOTE (atomicity): unlike publish (one Multi), rollback is N sequential
  # repoints AFTER the status flip commits. A mid-loop failure leaves the CR
  # `rolled_back` with pointers half-reverted; the status gate then blocks a
  # naive re-run. Acceptable for v1 (repoint is the same idempotent put_pointer
  # upsert the manual per-pointer rollback always was); flagged for follow-up.
  @doc false
  @spec handle_rollback_cr(map(), map()) :: {:ok, map(), [term()]} | {:error, term()}
  def handle_rollback_cr(args, ctx) do
    cr_id = Map.fetch!(args, :change_request_id)

    with {:ok, cr} <- fetch_self_cr_status(args, ctx, "published"),
         {:ok, %{cr: rolled_back, items: items}} <- Store.mark_rolled_back(cr_id),
         {:ok, effects} <- repoint_prior(cr, items, ctx) do
      {:ok, %{cr_id: rolled_back.id, status: rolled_back.status}, effects}
    end
  end

  # ---- CE-1 self-binding + CR ownership ------------------------------------

  # Fetch the CR and assert it targets THIS agent (CE-1). A caller managing
  # agent A cannot drive a CR whose subject is agent B.
  defp fetch_self_cr(args, ctx) do
    with {:ok, cr} <- ConfigGovernance.fetch_cr(Map.fetch!(args, :change_request_id)),
         :ok <- AgentPolicy.assert_self_cr(cr, ctx.self_uri) do
      {:ok, cr}
    end
  end

  defp fetch_self_cr_status(args, ctx, status) do
    with {:ok, cr} <- fetch_self_cr(args, ctx) do
      case ConfigGovernance.assert_status(cr, status) do
        :ok -> {:ok, cr}
        {:error, {:status_mismatch, detail}} -> {:error, {:cr_status, detail}}
      end
    end
  end

  # ---- rollback repoints (reuse ConfigEvolve.handle_repoint_config/2) -------

  # For each published item with a non-nil prior, call the EXISTING
  # `ConfigEvolve.handle_repoint_config/2` in-process with the SAME action ctx
  # (the agent IS the subject; that handler self-binds + scope-guards + flips +
  # emits the step-2 sandbox refresh). Aggregate every item's emitted effects.
  # A nil-prior item is skipped (SPEC §4.5 Q2). Returns `{:ok, effects}` or the
  # first `{:error, _}` (aborts the remaining repoints).
  defp repoint_prior(cr, items, ctx) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case item.published_prev_object_id do
        nil ->
          {:cont, {:ok, acc}}

        prior_id ->
          repoint_args = %{
            layer: layer_atom(item.layer),
            workspace_uri: cr_workspace_uri(cr),
            subject_uri: ctx.self_uri,
            key: item.key,
            config_id: prior_id
          }

          case ConfigEvolve.handle_repoint_config(repoint_args, ctx) do
            {:ok, _reply, effects} -> {:cont, {:ok, acc ++ effects}}
            {:error, _} = error -> {:halt, error}
          end
      end
    end)
  end

  defp cr_workspace_uri(cr), do: Ezagent.URI.new!(cr.workspace_uri)

  defp layer_atom("workspace"), do: :workspace
  defp layer_atom("user"), do: :user
  defp layer_atom("session"), do: :session

  # ---- materialization effect (reuse ConfigEvolve's public seam) -----------

  # Emit ONE deferred sandbox.update_config per affected (subject, key) — the same
  # current-pointer projection ConfigEvolve uses on its idempotent path. The
  # sandbox cache models the user-layer cascade per key; we project each distinct
  # key the CR touched (dedup). No new materialization mechanism.
  defp sandbox_effects_for_items(ctx, subject_uri, items) do
    # The reuse seam (current_user_object/object_layer_uri) needs a %URI{}; the
    # stored CR subject_uri is a string. The CR is self-bound (CE-1), so this is
    # always THIS agent — use ctx.self_uri (already a %URI{}).
    _ = subject_uri

    items
    |> Enum.map(& &1.key)
    |> Enum.uniq()
    |> Enum.flat_map(fn key ->
      ConfigEvolve.sandbox_refresh_effects(ctx, %{subject_uri: ctx.self_uri, key: key})
    end)
  end

  # ---- preview soul diff (deterministic render_soul/1) ---------------------

  defp with_soul_diff(%{current_body: current, proposed_body: proposed} = diff) do
    diff
    |> Map.put(:current_soul, ConfigProjection.render_soul(current))
    |> Map.put(:proposed_soul, ConfigProjection.render_soul(proposed))
  end
end
