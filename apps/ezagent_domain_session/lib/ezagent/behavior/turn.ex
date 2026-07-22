defmodule Ezagent.ActionSet.Turn do
  @moduledoc """
  Socialware orchestration state machine.

  Owns the `:turns` slice. Surface approval and customer visibility are
  layered in later phases; P1 records the durable turn lifecycle and emits
  worker delegation through dispatch.
  """

  # lifecycle:state_slice_override
  use Ezagent.Lifecycle, state_slice: :turns

  alias Ezagent.{Cmd, Message}

  @terminal_statuses [:settled, :cancelled]

  action(:open,
    args: %{trigger: :map, opened_at: :integer},
    returns: %{turn_id: :string},
    caps: [:open],
    modes: [:call],
    description: "Open a new socialware turn"
  )

  action(:dispatch,
    args: %{turn_id: :string, subtasks: {:list, :map}},
    returns: %{expected: {:list, :atom}},
    caps: [:dispatch],
    modes: [:call],
    description: "Record expected subtasks and delegate work through chat.send"
  )

  action(:deliver,
    args: %{turn_id: :string, subtask_id: :atom, card_ref: :map},
    returns: %{collected: {:list, :atom}},
    caps: [:deliver],
    modes: [:call],
    description: "Collect a worker deliverable for a turn"
  )

  action(:compose,
    args: %{turn_id: :string, result_refs: {:list, :map}},
    returns: %{status: :atom},
    caps: [:compose],
    modes: [:call],
    description: "Compose collected deliverables into a turn result"
  )

  action(:claim,
    args: %{turn_id: :string, by: :uri},
    returns: %{status: :atom},
    caps: [:claim],
    modes: [:call],
    description: "Move a composed turn into human review"
  )

  action(:settle,
    args: %{turn_id: :string},
    returns: %{status: :atom},
    caps: [:settle],
    modes: [:call],
    description: "Mark a composed or approved turn as settled"
  )

  action(:cancel,
    args: %{turn_id: :string},
    returns: %{status: :atom},
    caps: [:cancel],
    modes: [:call],
    description: "Cancel a non-terminal turn"
  )

  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{turns: %{}, turn_seq: 0}}

  @impl Ezagent.Lifecycle
  def activate(_state, _ctx), do: {:ok, %{}}

  # P2.5c crash-window recovery (codex rev2 HIGH). `activated/2` runs
  # post-`:ready` on every start, in the host GenServer process, and may
  # side-effect (its return is ignored — `Ezagent.Lifecycle.__run_activated__`).
  # The deferred settlement dispatch (the fast path) is an in-memory cast; a
  # crash AFTER the parent `:turns` commit marked the turn `:settled` but
  # BEFORE that cast ran would lose the customer delivery. So on every start we
  # self-signal a recovery scan — `handle_signal({:ezagent_recover_settlements},
  # _)` re-emits approve + commit_settlement (+ apply_delta) as NORMAL
  # `:dispatch` for any `:settled` turn whose durable side effect is still
  # outstanding. The two-step seam is required because ONLY `handle_signal/2`
  # emits an EXECUTED effect list (lifecycle.ex: `__run_signal__` →
  # `apply_signal_effects` → `Router.dispatch`); `activated/2` itself cannot.
  @impl Ezagent.Lifecycle
  def activated(_state, _ctx) do
    send(self(), {:ezagent_recover_settlements})
    :ok
  end

  # The recovery scan. `signal_ctx` (built by `Lifecycle.__run_signal__`)
  # exposes `:read` over the `:turns` slice + `:self_uri` — everything
  # `settle_commit_effects/4` needs. We re-emit NORMAL `{:dispatch, …}` (NOT
  # `:dispatch_after_commit`): the turn is ALREADY durably `:settled`, there is
  # no parent-commit-in-flight to gate against, and the signal path has no
  # deferred-effect consumer. Replay is gated per durable side effect so a
  # clean start (or already-applied turn) emits nothing:
  #   * settlement replay (approve + commit_settlement) ONLY when a `:pending`
  #     SettlementRecord exists for the turn;
  #   * config replay (apply_delta) ONLY when no ConfigObject was yet written
  #     for the turn (`source_turn_id` — apply_delta writes a NEW immutable
  #     config-object UUID, so it is NOT idempotent and must not re-run every
  #     restart).
  @impl Ezagent.Lifecycle
  @spec handle_signal(term(), map()) :: {:ok, [term()]} | :ignore
  def handle_signal({:ezagent_recover_settlements}, ctx) do
    turns = ctx.read.(:turns, %{})

    effects =
      turns
      |> Enum.filter(fn {_turn_id, turn} -> turn.status == :settled end)
      |> Enum.flat_map(fn {turn_id, turn} -> recovery_effects(turn_id, turn, ctx) end)

    {:ok, effects}
  end

  def handle_signal(_message, _ctx), do: :ignore

  # Per-turn recovery effects, each side effect independently gated on its own
  # durable not-yet-done marker so replay is idempotent + minimal.
  defp recovery_effects(turn_id, turn, ctx) do
    bootstrap_ctx =
      ctx
      |> Map.put(:caller, ctx.self_uri)
      |> Map.put(:authenticated_principal, ctx.self_uri)
      |> Map.put(:caps, recovery_caps(ctx))

    # The approve/commit settlement replays KEEP their bootstrap caps (the
    # session legitimately re-performing its OWN settlement side effects; out of
    # scope for H3).
    settlement_effects =
      if settlement_pending?(turn_id) do
        approve_and_commit_effects(turn_id, turn, bootstrap_ctx, :now)
      else
        []
      end

    # PR-3 Task 3.2 (H3 — DECIDED, Allen 2026-06-11) — the config-apply replay
    # MUST NOT bootstrap-launder authority. Re-validate it against the RECORDED
    # manager's CURRENT authority: read the manager URI off the durable turn
    # record and build the ctx with `caller: manager_uri` +
    # `caps: Ezagent.Identity.list_caps_for(manager_uri)`. The standard manage-cap
    # gate then re-checks the config replay — still holds it → apply; lost it →
    # denied by standard authz (skip + log; `source_turn_id` keeps a later fresh
    # dispatch idempotent). If NO manager URI was recorded (legacy/edge), the
    # replay is SKIPPED (fail-safe — never bootstrap-applied).
    config_effects =
      if config_replay_needed?(turn_id, turn) do
        config_recovery_effects(turn_id, turn, ctx)
      else
        []
      end

    settlement_effects ++ config_effects
  end

  defp recovery_caps(%{self_uri: %URI{} = session_uri}) do
    admin = Ezagent.URI.user(:system, :admin)

    [:approve, :commit_settlement]
    |> Enum.reduce_while({:ok, MapSet.new()}, fn action, {:ok, caps} ->
      target = Ezagent.URI.with_action(session_uri, :turn, action)

      case Ezagent.Cap.issue_for_action({:admin, admin}, session_uri, target) do
        {:ok, cap} -> {:cont, {:ok, MapSet.put(caps, cap)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, caps} -> caps
      {:error, _reason} -> MapSet.new()
    end
  end

  defp recovery_caps(_ctx), do: MapSet.new()

  # H3 — build the config-apply replay under the recorded manager's current
  # authority, or skip (fail-safe) when no manager was recorded.
  defp config_recovery_effects(turn_id, turn, ctx) do
    case Map.get(turn, :settler_uri) do
      nil ->
        :ok =
          log_skipped_config_replay(turn_id, turn)

        []

      manager_uri ->
        manager_ctx =
          ctx
          |> Map.put(:caller, manager_uri)
          |> Map.put(:authenticated_principal, manager_uri)
          |> Map.put(:caps, Ezagent.Identity.list_caps_for(manager_uri))

        config_update_effects(turn_id, turn, manager_ctx, :now)
    end
  end

  defp log_skipped_config_replay(turn_id, turn) do
    require Logger

    Logger.warning(
      "Turn config-replay SKIPPED on recovery: no manager URI recorded on the " <>
        "settled turn (legacy/edge). turn_id=#{inspect(turn_id)} " <>
        "subject=#{inspect(get_in(turn, [:result, :config_delta]) |> config_subject())}"
    )

    :ok
  end

  defp config_subject(%{} = delta),
    do: Map.get(delta, :subject_uri) || Map.get(delta, "subject_uri")

  defp config_subject(_), do: nil

  defp settlement_pending?(turn_id) do
    case Ezagent.Socialware.Settlement.get(turn_id) do
      {:ok, %{status: :pending}} -> true
      _ -> false
    end
  end

  # Config replay is needed when the settled turn carries a `config_delta` but
  # it was not yet DURABLY APPLIED for it. CE-3: "applied" is OBJECT-EXISTENCE —
  # `applied_for_turn?/1` returns true iff a ConfigObject stamped with this
  # turn exists. This is sound because `write_and_point/1` is atomic (object +
  # pointer in one transaction), so an orphan object cannot exist and a
  # genuinely-interrupted apply leaves neither object nor pointer → replay
  # correctly fires. (A superseded turn's object still exists, so it stays
  # applied and is NOT replayed — PR-6 fix for the pointer-aware regression.)
  defp config_replay_needed?(turn_id, %{result: %{config_delta: delta}}) when is_map(delta) do
    not Ezagent.Socialware.ConfigStore.applied_for_turn?(turn_id)
  end

  defp config_replay_needed?(_turn_id, _turn), do: false

  @spec reads_siblings() :: [:surface]
  def reads_siblings, do: [:surface]

  @spec data_owner(URI.t() | :any | term()) :: URI.t() | :any | :no_owner
  def data_owner(%URI{scheme: "session"} = session_uri) do
    Ezagent.ActionSet.Session.data_owner(session_uri)
  end

  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner

  @spec handle_open(map(), map()) :: {:ok, map(), [term()]}
  def handle_open(%{trigger: trigger, opened_at: opened_at}, ctx) do
    turns = ctx.read.(:turns, %{})
    turn_no = ctx.read.(:turn_seq, 0) + 1
    turn_id = turn_id(ctx.self_uri, turn_no)

    turn = %{
      trigger: trigger,
      owner: ctx.caller,
      mode: publish_mode(ctx),
      expected: MapSet.new(),
      collected: %{},
      result: [],
      status: :open,
      turn_no: turn_no,
      opened_at: opened_at,
      # PR-3 Task 3.1b — the settling manager URI, recorded at `handle_settle`
      # (nil until then; H3 recovery reads it to re-validate the config replay).
      settler_uri: nil
    }

    {:ok, %{turn_id: turn_id},
     [
       {:set, :turns, Map.put(turns, turn_id, turn)},
       {:set, :turn_seq, turn_no}
     ]}
  end

  @spec handle_dispatch(map(), map()) :: {:ok, map(), [term()]} | {:error, term()}
  def handle_dispatch(%{turn_id: turn_id, subtasks: subtasks}, ctx) do
    update_turn(ctx, turn_id, fn turn ->
      if terminal?(turn.status) do
        {:error, {:illegal_transition, turn.status}}
      else
        subtask_ids = Enum.map(subtasks, &subtask_id!/1)
        expected = MapSet.new(subtask_ids)
        updated = %{turn | expected: expected, status: :delegating}
        dispatches = Enum.map(subtasks, &dispatch_subtask(&1, turn_id, ctx))

        {:ok, updated, %{expected: subtask_ids}, dispatches}
      end
    end)
  end

  @spec handle_deliver(map(), map()) :: {:ok, map(), [term()]} | {:error, term()}
  def handle_deliver(%{turn_id: turn_id, subtask_id: subtask_id, card_ref: card_ref}, ctx) do
    update_turn(ctx, turn_id, fn turn ->
      cond do
        not MapSet.member?(turn.expected, subtask_id) ->
          {:error, :unexpected_subtask}

        terminal?(turn.status) ->
          {:error, {:illegal_transition, turn.status}}

        true ->
          collected = Map.put(turn.collected, subtask_id, card_ref)
          updated = %{turn | collected: collected, status: :aggregating}
          {:ok, updated, %{collected: Map.keys(collected)}, []}
      end
    end)
  end

  @spec handle_compose(map(), map()) :: {:ok, map(), [term()]} | {:error, term()}
  def handle_compose(%{turn_id: turn_id, result_refs: result_refs}, ctx) do
    update_turn(ctx, turn_id, fn turn ->
      case compose_allowed?(turn) do
        :ok ->
          {result, reply, effects} = compose_result_and_effects(turn, turn_id, result_refs, ctx)
          updated = %{turn | result: result, status: :composing}
          {:ok, updated, reply, effects}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  @spec handle_claim(map(), map()) :: {:ok, map(), [term()]} | {:error, term()}
  def handle_claim(%{turn_id: turn_id, by: by}, ctx) do
    with :ok <- authorize_content_actor(ctx) do
      update_turn(ctx, turn_id, fn turn ->
        case transition(turn.status, :awaiting_human) do
          :ok ->
            :ok = hold_visibility(turn)
            updated = %{turn | owner: by, mode: :copilot, status: :awaiting_human}
            {:ok, updated, %{status: :awaiting_human}, []}

          {:error, reason} ->
            {:error, reason}
        end
      end)
    end
  end

  @spec handle_settle(map(), map()) :: {:ok, map(), [term()]} | {:error, term()}
  def handle_settle(%{turn_id: turn_id}, ctx) do
    with :ok <- authorize_content_actor(ctx) do
      update_turn(ctx, turn_id, fn turn ->
        case transition(turn.status, :settled) do
          :ok ->
            case prepare_settlement(turn_id, turn, ctx) do
              :ok ->
                # PR-3 Task 3.1b (H3) — record the MANAGER URI (the settling caller
                # whose authority gated the config apply) on the durable turn
                # record, keyed by turn. Recovery (`recovery_effects`) reads it to
                # re-validate the config replay against the manager's CURRENT
                # authority instead of bootstrap-laundering. Backward-tolerant:
                # `nil` when the caller is absent (legacy turns → replay skipped).
                updated = %{
                  turn
                  | status: :settled,
                    settler_uri: Map.get(ctx, :authenticated_principal)
                }

                # P2.5c — settle FAST PATH: emit settlement/config dispatches as
                # `:dispatch_after_commit` so they run only after the parent
                # `:turns` slice durably commits.
                {:ok, updated, %{status: :settled},
                 settle_commit_effects(turn_id, turn, ctx, :after_commit)}

              {:error, reason} ->
                {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end
      end)
    end
  end

  @spec handle_cancel(map(), map()) :: {:ok, map(), [term()]} | {:error, term()}
  def handle_cancel(%{turn_id: turn_id}, ctx) do
    update_turn(ctx, turn_id, fn turn ->
      case transition(turn.status, :cancelled) do
        :ok ->
          updated = %{turn | status: :cancelled}
          {:ok, updated, %{status: :cancelled}, []}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  defp update_turn(ctx, turn_id, fun) do
    turns = ctx.read.(:turns, %{})

    case Map.fetch(turns, turn_id) do
      {:ok, turn} ->
        case fun.(turn) do
          {:ok, updated_turn, result, effects} ->
            {:ok, result, [{:set, :turns, Map.put(turns, turn_id, updated_turn)} | effects]}

          {:error, reason} ->
            {:error, reason}
        end

      :error ->
        {:error, :unknown_turn}
    end
  end

  defp turn_id(%URI{} = session_uri, turn_no) do
    URI.to_string(session_uri) <> "#turn-" <> Integer.to_string(turn_no)
  end

  defp dispatch_subtask(subtask, turn_id, ctx) do
    subtask_id = subtask_id!(subtask)
    mention = fetch_subtask!(subtask, :mention)
    prompt = fetch_subtask!(subtask, :prompt)

    message =
      Message.new(
        ctx.caller,
        %{
          text: prompt,
          attachments: [],
          metadata: %{
            correlation: %{
              turn_id: turn_id,
              subtask_id: Atom.to_string(subtask_id)
            }
          }
        },
        mentions: [mention]
      )

    {:dispatch, Cmd.new(ctx.self_uri, :send, %{message: message}, dispatch_ctx(ctx))}
  end

  defp compose_result_and_effects(turn, turn_id, result_refs, ctx) do
    message_ids = write_chat_messages(turn, result_refs, ctx)
    expected_prior_approved = current_surface_approved(ctx)

    {version, page_effects} =
      case page_tree_for(turn, result_refs) do
        nil ->
          {nil, []}

        page_tree ->
          version = next_surface_version(ctx)

          effect =
            {:dispatch,
             Cmd.new(
               ctx.self_uri,
               :put_version,
               %{turn_id: turn_id, tree: page_tree},
               dispatch_ctx(ctx)
             )}

          {version, [effect]}
      end

    result =
      %{
        refs: result_refs,
        message_ids: message_ids,
        version: version,
        expected_prior_approved: expected_prior_approved
      }
      |> maybe_put(:config_delta, config_delta_for(result_refs))

    reply =
      %{status: :composing}
      |> maybe_put(:version, version)
      |> maybe_put(:message_ids, message_ids)

    {result, reply, page_effects}
  end

  defp hold_visibility(%{result: %{message_ids: message_ids}})
       when is_list(message_ids) and message_ids != [] do
    {:ok, _count} = Ezagent.MessageStore.mark_visibility(message_ids, :internal)
    :ok
  end

  defp hold_visibility(_turn), do: :ok

  defp approve_and_commit_effects(turn_id, %{result: %{version: version}}, ctx, dispatch_kind)
       when is_integer(version) do
    [
      effect(
        dispatch_kind,
        Cmd.new(ctx.self_uri, :approve, %{version: version}, dispatch_ctx(ctx))
      ),
      effect(
        dispatch_kind,
        Cmd.new(ctx.self_uri, :commit_settlement, %{turn_id: turn_id}, dispatch_ctx(ctx))
      )
    ]
  end

  defp approve_and_commit_effects(turn_id, _turn, ctx, dispatch_kind) do
    [
      effect(
        dispatch_kind,
        Cmd.new(ctx.self_uri, :commit_settlement, %{turn_id: turn_id}, dispatch_ctx(ctx))
      )
    ]
  end

  # P2.5c — the settle-time settlement/config dispatches (approve /
  # commit_settlement / apply_delta) are the durable customer-facing side
  # effects that MUST NOT outlive a failed parent `:turns` commit.
  #
  # `dispatch_kind` parameterizes WHEN they run:
  #   * `:after_commit` (the settle FAST PATH, `handle_settle`) emits
  #     `{:dispatch_after_commit, …}` — the runtime defers them so
  #     `Kind.Server` runs them only after the parent `:turns` slice durably
  #     commits (closes the rev4 orphan-delivery bug).
  #   * `:now` (the CRASH-RECOVERY path, `activated/2` → self-signal →
  #     `handle_signal/2`) emits normal `{:dispatch, …}` — the turn is
  #     ALREADY durably `:settled`, there is no parent-commit-in-flight to
  #     gate against, and the signal path has no deferred-effect consumer.
  #     Replay is idempotent (re-approve same version; commit_after_pointer
  #     no-ops when already committed).
  defp settle_commit_effects(turn_id, turn, ctx, dispatch_kind) do
    settlement_effects =
      if settlement_needed?(turn) do
        approve_and_commit_effects(turn_id, turn, ctx, dispatch_kind)
      else
        []
      end

    settlement_effects ++ config_update_effects(turn_id, turn, ctx, dispatch_kind)
  end

  # P2.5c — wrap a `%Cmd{}` in the effect tuple matching the requested
  # dispatch timing.
  defp effect(:after_commit, %Cmd{} = cmd), do: {:dispatch_after_commit, cmd}
  defp effect(:now, %Cmd{} = cmd), do: {:dispatch, cmd}

  defp settlement_attrs(turn_id, turn, ctx) do
    result = Map.get(turn, :result, %{})

    %{
      turn_id: turn_id,
      session_uri: ctx.self_uri,
      workspace_uri: Ezagent.Persistence.workspace_uri_for!(ctx.self_uri),
      target_message_ids: Map.get(result, :message_ids, []),
      target_surface_version: Map.get(result, :version),
      expected_prior_approved: Map.get(result, :expected_prior_approved)
    }
  end

  defp prepare_settlement(turn_id, turn, ctx) do
    if settlement_needed?(turn) do
      with {:ok, _settlement} <-
             Ezagent.Socialware.Settlement.begin(settlement_attrs(turn_id, turn, ctx)),
           {:ok, _settlement} <- Ezagent.Socialware.Settlement.flip_visibility(turn_id) do
        :ok
      end
    else
      :ok
    end
  end

  defp settlement_needed?(%{result: %{message_ids: message_ids, version: version}}) do
    (is_list(message_ids) and message_ids != []) or is_integer(version)
  end

  defp settlement_needed?(_turn), do: false

  defp page_tree_for(turn, result_refs) do
    turn.collected
    |> Map.values()
    |> Kernel.++(result_refs)
    |> Enum.find_value(&page_tree_from_ref/1)
  end

  defp page_tree_from_ref(ref) when is_map(ref) do
    kind =
      Map.get(ref, :kind) || Map.get(ref, "kind") || Map.get(ref, :type) || Map.get(ref, "type")

    tree = Map.get(ref, :tree) || Map.get(ref, "tree")

    if kind in [:page, "page"] and is_map(tree), do: tree
  end

  defp page_tree_from_ref(_ref), do: nil

  defp config_delta_for(result_refs) do
    Enum.find_value(result_refs, &config_delta_from_ref/1)
  end

  defp config_delta_from_ref(ref) when is_map(ref) do
    kind =
      Map.get(ref, :kind) || Map.get(ref, "kind") || Map.get(ref, :type) || Map.get(ref, "type")

    if kind in [:config_delta, "config_delta"], do: ref
  end

  defp config_delta_from_ref(_ref), do: nil

  defp write_chat_messages(turn, result_refs, ctx) do
    result_refs
    |> Enum.flat_map(&write_chat_message_from_ref(&1, turn, ctx))
  end

  defp write_chat_message_from_ref(ref, turn, ctx) when is_map(ref) do
    kind =
      Map.get(ref, :kind) || Map.get(ref, "kind") || Map.get(ref, :type) || Map.get(ref, "type")

    text = Map.get(ref, :text) || Map.get(ref, "text")

    if kind in [:chat, "chat", :message, "message"] and is_binary(text) do
      message =
        Message.new(
          ctx.caller,
          %{text: text, attachments: Map.get(ref, :attachments, Map.get(ref, "attachments", []))},
          visibility: initial_visibility(turn)
        )

      case Ezagent.MessageStore.write(message, ctx.self_uri) do
        {:ok, written} -> [written.id]
        {:error, reason} -> raise "socialware turn chat write failed: #{inspect(reason)}"
      end
    else
      []
    end
  end

  defp write_chat_message_from_ref(_ref, _turn, _ctx), do: []

  defp initial_visibility(%{mode: :auto}), do: :external_visible
  defp initial_visibility(_turn), do: :internal

  defp publish_mode(%{self_uri: %URI{} = session_uri}) do
    Ezagent.Socialware.Installation.publish_policy(session_uri)
  rescue
    DBConnection.OwnershipError -> :auto
  end

  defp publish_mode(_ctx), do: :auto

  defp next_surface_version(ctx) do
    ctx
    |> Map.get(:siblings, %{})
    |> Map.get(:surface, %{})
    |> Map.get(:version_seq, 0)
    |> Kernel.+(1)
  end

  defp current_surface_approved(ctx) do
    ctx
    |> Map.get(:siblings, %{})
    |> Map.get(:surface, %{})
    |> Map.get(:approved)
  end

  # PR-3 cut-over (spec 2026-06-11 §5) — the settlement no longer self-dispatches
  # `:apply_delta` to the SESSION (the old `ConfigUpdate`). It extracts the
  # target agent (`subject_uri`) from the settled `config_delta` and dispatches
  # `config_evolve.apply_config_delta` to THAT AGENT, forwarding the delta fields
  # as args (the agent has no `:turns` slice, so the delta rides on the dispatch
  # args — matching ConfigEvolve's `apply_config_delta` arg shape). The dispatch
  # carries the settling manager's caps (`dispatch_ctx`), and the agent-side
  # manage-cap gate (§4) re-validates authority. If `subject_uri` is absent there
  # is no target, so emit nothing.
  defp config_update_effects(turn_id, %{result: %{config_delta: delta}}, ctx, dispatch_kind)
       when is_map(delta) do
    case delta_subject_uri(delta) do
      nil ->
        []

      subject ->
        [
          effect(
            dispatch_kind,
            Cmd.new(
              ensure_uri(subject),
              :apply_config_delta,
              apply_config_delta_args(turn_id, delta),
              dispatch_ctx(ctx)
            )
          )
        ]
    end
  end

  defp config_update_effects(_turn_id, _turn, _ctx, _dispatch_kind), do: []

  # The delta is a result-ref map whose keys may be atoms (composed in-process)
  # or strings (rehydrated from a snapshot); read both.
  defp delta_field(delta, key) when is_atom(key) do
    Map.get(delta, key) || Map.get(delta, Atom.to_string(key))
  end

  defp delta_subject_uri(delta), do: delta_field(delta, :subject_uri)

  # Forward the settled delta's fields as `apply_config_delta` args. `turn_id`
  # is the idempotency marker (`source_turn_id`); optional fields default on the
  # agent side when absent.
  defp apply_config_delta_args(turn_id, delta) do
    %{turn_id: turn_id}
    |> maybe_put(:layer, delta_field(delta, :layer))
    |> maybe_put(:workspace_uri, delta_field(delta, :workspace_uri))
    |> maybe_put(:subject_uri, ensure_uri(delta_field(delta, :subject_uri)))
    |> maybe_put(:key, delta_field(delta, :key))
    |> maybe_put(:patch, delta_field(delta, :patch))
  end

  defp ensure_uri(nil), do: nil
  defp ensure_uri(%URI{} = uri), do: uri
  defp ensure_uri(uri) when is_binary(uri), do: Ezagent.URI.new!(uri)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp dispatch_ctx(ctx) do
    %{
      # P2.5c — the action path always carries `:caller`; the recovery signal
      # path (`handle_signal({:ezagent_recover_settlements}, _)`) does NOT, so
      # default to the session's own `:self_uri` (these are self-dispatches the
      # session makes to itself — the same identity the runtime's
      # `enrich_dispatch_cmd` would default to anyway).
      caller: Map.get(ctx, :caller) || Map.get(ctx, :self_uri),
      # F-6: forward the authenticated holder explicitly. Autonomous recovery
      # installs the Session principal in `recovery_effects/3`; ordinary action
      # paths never fall back from a missing holder to `ctx.caller`.
      authenticated_principal: Map.get(ctx, :authenticated_principal),
      caps: Map.get(ctx, :caps, MapSet.new()),
      reply: :ignore,
      trace_id: Map.get(ctx, :trace_id),
      deadline_ms: Map.get(ctx, :deadline_ms)
    }
  end

  # Session-content mutation is membership-gated on the authenticated holder.
  # The only non-identity exception is the Session Kind's own durable recovery
  # replay, whose explicit self holder is installed above before dispatch.
  defp authorize_content_actor(ctx), do: Ezagent.Session.ContentActor.authorize(ctx)

  defp subtask_id!(subtask), do: fetch_subtask!(subtask, :id)

  defp fetch_subtask!(subtask, key) do
    case Map.fetch(subtask, key) do
      {:ok, value} -> value
      :error -> Map.fetch!(subtask, Atom.to_string(key))
    end
  end

  defp compose_allowed?(%{status: :aggregating}), do: :ok

  defp compose_allowed?(%{status: :open, expected: expected}) do
    if MapSet.size(expected) == 0 do
      :ok
    else
      {:error, {:illegal_transition, :open}}
    end
  end

  defp compose_allowed?(%{status: status}), do: {:error, {:illegal_transition, status}}

  defp transition(status, _to) when status in @terminal_statuses,
    do: {:error, {:illegal_transition, status}}

  defp transition(:composing, :awaiting_human), do: :ok
  defp transition(:composing, :settled), do: :ok
  defp transition(:awaiting_human, :settled), do: :ok
  defp transition(status, :cancelled) when status not in @terminal_statuses, do: :ok
  defp transition(status, _to), do: {:error, {:illegal_transition, status}}

  defp terminal?(status), do: status in @terminal_statuses
end
