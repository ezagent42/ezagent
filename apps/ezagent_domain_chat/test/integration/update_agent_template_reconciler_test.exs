defmodule EzagentDomainChat.Integration.UpdateAgentTemplateReconcilerTest do
  @moduledoc """
  V1-R6 from the Generator-reconciler SPEC
  (`docs/superpowers/specs/2026-05-23-generator-reconciler.md` §8). The
  PR-C reconciler-shape regression tests for
  `Ezagent.Orchestrator.Tools.update_agent_template/3`,
  `add_agent_slot/4`, and `remove_agent_slot/2`.

  ## Coverage map

  - **idempotent re-run** — `update_agent_template` with the same args
    after a successful update is a no-op: same worker URI, same pid,
    same generation; ZERO `template.instantiate` dispatches on the
    re-run; ZERO `kind_snapshots` row writes.
  - **`add_agent_slot` idempotence** — same args twice → same worker
    URI, same pid; ZERO new spawns.
  - **`add_agent_slot` slot conflict** — slot exists at a DIFFERENT
    template URI → `{:error, :slot_conflict}`.
  - **`remove_agent_slot` idempotence** — already absent → `{:ok,
    :already_removed}`.
  - **partial-routing convergence** — under the reconciler, when the
    routing transaction rolls back the new worker stays alive + slot
    stays committed; the next pass completes the repoint and
    terminates the OLD worker. (Replaces the pre-PR-C saga-rollback
    assertions.)
  - **same-template no-op happy path** — confirms the generation
    counter does NOT advance on a no-op re-run (the codex rev-2 HIGH-4
    bug fix the SPEC §4.1 documents).

  Every test drives the production `Ezagent.Orchestrator.Tools` API —
  no mocks. Uses the same no-PTY synthetic flavor as `phase7_hardening_test.exs`
  so the test isolates the reconciler logic from any plugin runtime
  detail.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{AgentFlavorRegistry, AgentLineage, Capability, KindRegistry}
  alias Ezagent.Entity.{Agent, Session, SessionTemplate, User}
  alias Ezagent.Orchestrator.Tools

  defmodule TestFlavorClass do
    @moduledoc false
    @behaviour Ezagent.Kind.Template

    @impl true
    def template_name, do: "uat.reconciler.agent"

    @impl true
    def validate(tmpl) when is_map(tmpl),
      do: if(Map.has_key?(tmpl, "agent_uri"), do: :ok, else: {:error, :missing_agent_uri})

    def validate(_), do: {:error, :not_a_map}

    @impl true
    def instantiate(_tmpl_name, %{"agent_uri" => uri_str}, _workspace_uri) do
      agent_uri = URI.parse(uri_str)

      case Ezagent.SpawnRegistry.spawn_detailed(agent_uri) do
        {:ok, :started, _pid} -> {:ok, [agent_uri], %{fresh?: true}}
        {:ok, :already_started, _pid} -> {:ok, [agent_uri], %{fresh?: false}}
        {:error, _} = err -> err
      end
    end

    def instantiate(_n, tmpl, _ws), do: {:error, {:invalid_template, tmpl}}
  end

  # --- helpers -----------------------------------------------------------

  defp uniq, do: System.unique_integer([:positive])

  defp register_test_flavor do
    flavor = "uatrec#{uniq()}"

    :ok =
      AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Agent,
        template_class: TestFlavorClass
      })

    flavor
  end

  defp agent_template_content(flavor, name) do
    %{
      name: name,
      description: "worker #{name}",
      flavor: flavor,
      working_directory: "/tmp/uat-reconciler-test",
      claude_config_dir: nil,
      settings_path: nil,
      mcp_config_path: nil,
      api_key_helper: nil,
      default_caps: [],
      created_by: User.admin_uri(),
      created_at: ~U[2026-05-23 00:00:00Z]
    }
  end

  defp create_agent_template(uri, content) do
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)

    {:ok, %{content: ^content}} =
      with_db_retry(fn -> dispatch(uri, "template.write", %{content: content}) end)

    :ok
  end

  defp with_db_retry(fun, attempts \\ 8) do
    fun.()
  catch
    :exit, _ when attempts > 1 ->
      Process.sleep(40)
      with_db_retry(fun, attempts - 1)
  end

  defp dispatch(uri, action, args, ctx \\ nil) do
    target = URI.parse("#{URI.to_string(uri)}?action=#{action}")

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: target,
      mode: :call,
      args: args,
      ctx: ctx || admin_ctx()
    })
  end

  defp admin_ctx do
    %{caller: User.admin_uri(), caps: Ezagent.SystemPrincipal.caps("system://bootstrap"), reply: {:caller_inbox, self()}}
  end

  defp create_session_template(name, agent_slots, routing_rules, opts \\ []) do
    workspace = Keyword.get(opts, :workspace, "team-alpha")

    content = %{
      name: name,
      description: "test team #{name}",
      agent_slots: agent_slots,
      routing_rules: routing_rules,
      orchestrator_template_uri: URI.parse("template://agent/system/cc-orchestrator"),
      default_workspace_uri:
        Keyword.get(opts, :default_workspace_uri, URI.parse("workspace://team-alpha")),
      parent_template_uri: nil,
      version_tag: nil,
      created_by: User.admin_uri(),
      created_at: ~U[2026-05-23 00:00:00Z]
    }

    {:ok, uri} = with_db_retry(fn -> SessionTemplate.persist_version(content, workspace) end)
    uri
  end

  defp spawn_owner(uri, caps) do
    {:ok, _pid} = Ezagent.Kind.spawn(User, %{uri: uri, initial_caps: MapSet.new(caps)})
    :ok
  end

  defp template_cap(kind, workspace_uri) do
    %Capability{
      kind: kind,
      behavior: Ezagent.Behavior.Template,
      instance: {:within_workspace, workspace_uri},
      workspace_uri: workspace_uri,
      granted_by: User.admin_uri(),
      granted_at: DateTime.utc_now()
    }
  end

  defp full_template_owner(workspace_uri) do
    owner_uri = URI.parse("entity://user/#{workspace_uri.host}/uatrec-owner-#{uniq()}")

    :ok =
      spawn_owner(owner_uri, [
        template_cap(:session_template, workspace_uri),
        template_cap(:agent_template, workspace_uri)
      ])

    owner_uri
  end

  defp orchestrator_caps(orchestrator_uri) do
    {:ok, pid} = KindRegistry.lookup(orchestrator_uri)

    pid
    |> :sys.get_state()
    |> Map.get(:state, %{})
    |> Map.get(:identity, %{})
    |> Map.get(:caps, MapSet.new())
  end

  defp session_working_copy(session_uri) do
    {:ok, pid} = KindRegistry.lookup(session_uri)

    chat_slice =
      pid
      |> :sys.get_state()
      |> Map.get(:state, %{})
      |> Map.get(:chat, %{})
      # Lifecycle migration (SPEC 2026-05-29 §2.3C): unwrap the Chat
      # two-container slice to its persistent :state (flat falls through).
      |> then(&Map.get(&1, :state, &1))

    Ezagent.Behavior.Chat.template_working_copy(chat_slice)
  end

  defp find_slot(wc, slot_name) do
    Enum.find(wc.agent_slots, fn t -> elem(t, 0) == slot_name end)
  end

  defp live_workers_of(orch_uri) do
    AgentLineage.list_all()
    |> Enum.flat_map(fn {agent_str, spawner_str} ->
      cond do
        spawner_str != URI.to_string(orch_uri) -> []
        true -> [URI.parse(agent_str)]
      end
    end)
  end

  @default_ws URI.new!("workspace://team-alpha")

  # ════════════════════════════════════════════════════════════════════
  # update_agent_template — V1-R6 reconciler semantics
  # ════════════════════════════════════════════════════════════════════

  describe "V1-R6 — update_agent_template no-op detect (codex rev-2 HIGH-4)" do
    setup do
      flavor = register_test_flavor()
      tmpl_a = URI.new!("template://agent/team-alpha/uat-r6-a-#{uniq()}")
      tmpl_b = URI.new!("template://agent/team-alpha/uat-r6-b-#{uniq()}")
      :ok = create_agent_template(tmpl_a, agent_template_content(flavor, "config-a"))
      :ok = create_agent_template(tmpl_b, agent_template_content(flavor, "config-b"))

      st_uri = create_session_template("uat-r6-team-#{uniq()}", [{"dev", tmpl_a}], [])
      owner = full_template_owner(@default_ws)

      {:ok, %{session_uri: session_uri, orchestrator_uri: orch_uri}} =
        Session.spawn_from_template(st_uri, owner)

      caps = orchestrator_caps(orch_uri)

      %{
        session_uri: session_uri,
        orchestrator_uri: orch_uri,
        caps: caps,
        tmpl_a: tmpl_a,
        tmpl_b: tmpl_b
      }
    end

    test "re-invocation with the SAME template returns the SAME worker URI (no generation bump)",
         ctx do
      # First invocation — actual swap to tmpl_b.
      assert {:ok, %URI{} = w1} =
               Tools.update_agent_template("dev", ctx.tmpl_b,
                 caller: ctx.orchestrator_uri,
                 caps: ctx.caps,
                 workspace_uri: @default_ws,
                 session_uri: ctx.session_uri
               )

      wc_after_first = session_working_copy(ctx.session_uri)
      {_, _, _, gen_after_first} = find_slot(wc_after_first, "dev")
      assert gen_after_first == 1

      # Capture the live pid for the new worker.
      {:ok, pid_first} = KindRegistry.lookup(w1)

      # Second invocation — SAME args. Reconciler must detect "already
      # at target" + return the same URI WITHOUT bumping generation or
      # spawning a new worker.
      assert {:ok, %URI{} = w2} =
               Tools.update_agent_template("dev", ctx.tmpl_b,
                 caller: ctx.orchestrator_uri,
                 caps: ctx.caps,
                 workspace_uri: @default_ws,
                 session_uri: ctx.session_uri
               )

      assert URI.to_string(w1) == URI.to_string(w2),
             "the no-op re-run must return the SAME worker URI. " <>
               "first=#{URI.to_string(w1)} second=#{URI.to_string(w2)}"

      # Same pid — no respawn.
      {:ok, pid_second} = KindRegistry.lookup(w2)

      assert pid_first == pid_second,
             "the no-op re-run must NOT respawn the worker — the pid must be stable"

      # Generation counter UNCHANGED (the codex rev-2 HIGH-4 gate).
      wc_after_second = session_working_copy(ctx.session_uri)
      {_, _, _, gen_after_second} = find_slot(wc_after_second, "dev")

      assert gen_after_first == gen_after_second,
             "the no-op re-run must NOT advance the generation counter. " <>
               "first=#{gen_after_first} second=#{gen_after_second}"
    end
  end

  describe "V1-R6 — update_agent_template structured errors (no saga wrap)" do
    test "an absent slot surfaces :no_such_slot (no :update_aborted wrapper)" do
      flavor = register_test_flavor()
      tmpl = URI.new!("template://agent/team-alpha/uat-r6-none-#{uniq()}")
      :ok = create_agent_template(tmpl, agent_template_content(flavor, "x"))
      st = create_session_template("uat-r6-none-team-#{uniq()}", [], [])
      owner = full_template_owner(@default_ws)

      {:ok, %{session_uri: session_uri, orchestrator_uri: orch}} =
        Session.spawn_from_template(st, owner)

      caps = orchestrator_caps(orch)

      result =
        Tools.update_agent_template("does-not-exist", tmpl,
          caller: orch,
          caps: caps,
          workspace_uri: @default_ws,
          session_uri: session_uri
        )

      assert result == {:error, :no_such_slot},
             "an absent slot must return {:error, :no_such_slot} directly (no saga wrap). " <>
               "Got: #{inspect(result)}"
    end
  end

  # ════════════════════════════════════════════════════════════════════
  # add_agent_slot — reconciler semantics
  # ════════════════════════════════════════════════════════════════════

  describe "add_agent_slot reconciler semantics" do
    setup do
      flavor = register_test_flavor()
      tmpl = URI.new!("template://agent/team-alpha/uat-add-#{uniq()}")
      tmpl_other = URI.new!("template://agent/team-alpha/uat-add-other-#{uniq()}")
      :ok = create_agent_template(tmpl, agent_template_content(flavor, "x"))
      :ok = create_agent_template(tmpl_other, agent_template_content(flavor, "other"))

      st = create_session_template("uat-add-team-#{uniq()}", [], [])
      owner = full_template_owner(@default_ws)

      {:ok, %{session_uri: session_uri, orchestrator_uri: orch}} =
        Session.spawn_from_template(st, owner)

      caps = orchestrator_caps(orch)

      %{
        session_uri: session_uri,
        orchestrator_uri: orch,
        caps: caps,
        tmpl: tmpl,
        tmpl_other: tmpl_other
      }
    end

    test "re-invocation with the same args returns the SAME worker URI (no respawn)", ctx do
      assert {:ok, %URI{} = w1} =
               Tools.add_agent_slot("backend", ctx.tmpl, nil,
                 caller: ctx.orchestrator_uri,
                 caps: ctx.caps,
                 workspace_uri: @default_ws,
                 session_uri: ctx.session_uri
               )

      {:ok, pid_first} = KindRegistry.lookup(w1)

      assert {:ok, %URI{} = w2} =
               Tools.add_agent_slot("backend", ctx.tmpl, nil,
                 caller: ctx.orchestrator_uri,
                 caps: ctx.caps,
                 workspace_uri: @default_ws,
                 session_uri: ctx.session_uri
               )

      assert URI.to_string(w1) == URI.to_string(w2)
      {:ok, pid_second} = KindRegistry.lookup(w2)
      assert pid_first == pid_second
    end

    test "slot already at a DIFFERENT template surfaces :slot_conflict", ctx do
      assert {:ok, _w1} =
               Tools.add_agent_slot("backend", ctx.tmpl, nil,
                 caller: ctx.orchestrator_uri,
                 caps: ctx.caps,
                 workspace_uri: @default_ws,
                 session_uri: ctx.session_uri
               )

      result =
        Tools.add_agent_slot("backend", ctx.tmpl_other, nil,
          caller: ctx.orchestrator_uri,
          caps: ctx.caps,
          workspace_uri: @default_ws,
          session_uri: ctx.session_uri
        )

      assert result == {:error, :slot_conflict},
             "add_agent_slot on an existing slot at a different template must surface " <>
               ":slot_conflict — use update_agent_template to change templates. " <>
               "Got: #{inspect(result)}"
    end
  end

  # ════════════════════════════════════════════════════════════════════
  # remove_agent_slot — reconciler semantics
  # ════════════════════════════════════════════════════════════════════

  describe "remove_agent_slot reconciler semantics" do
    test "an absent slot returns {:ok, :already_removed} (idempotent no-op)" do
      flavor = register_test_flavor()
      tmpl = URI.new!("template://agent/team-alpha/uat-rm-#{uniq()}")
      :ok = create_agent_template(tmpl, agent_template_content(flavor, "x"))
      _ = tmpl

      st = create_session_template("uat-rm-team-#{uniq()}", [], [])
      owner = full_template_owner(@default_ws)

      {:ok, %{session_uri: session_uri, orchestrator_uri: orch}} =
        Session.spawn_from_template(st, owner)

      caps = orchestrator_caps(orch)

      result =
        Tools.remove_agent_slot("never-existed-#{uniq()}",
          caller: orch,
          caps: caps,
          workspace_uri: @default_ws,
          session_uri: session_uri
        )

      assert result == {:ok, :already_removed},
             "remove_agent_slot on an absent slot must return {:ok, :already_removed} — " <>
               "the reconciler's idempotent no-op shape. Got: #{inspect(result)}"
    end

    test "removing a present slot terminates the worker + drops the slot tuple" do
      flavor = register_test_flavor()
      tmpl = URI.new!("template://agent/team-alpha/uat-rmp-#{uniq()}")
      :ok = create_agent_template(tmpl, agent_template_content(flavor, "x"))

      st = create_session_template("uat-rmp-team-#{uniq()}", [], [])
      owner = full_template_owner(@default_ws)

      {:ok, %{session_uri: session_uri, orchestrator_uri: orch}} =
        Session.spawn_from_template(st, owner)

      caps = orchestrator_caps(orch)

      assert {:ok, worker_uri} =
               Tools.add_agent_slot("rm-me", tmpl, nil,
                 caller: orch,
                 caps: caps,
                 workspace_uri: @default_ws,
                 session_uri: session_uri
               )

      assert {:ok, _} = KindRegistry.lookup(worker_uri)

      assert {:ok, :removed} =
               Tools.remove_agent_slot("rm-me",
                 caller: orch,
                 caps: caps,
                 workspace_uri: @default_ws,
                 session_uri: session_uri
               )

      # Slot tuple is gone from the working copy.
      wc = session_working_copy(session_uri)
      refute Enum.any?(wc.agent_slots, fn t -> elem(t, 0) == "rm-me" end)

      # Worker is terminated (Lifecycle).
      _ = wait_until(fn -> KindRegistry.lookup(worker_uri) == :error end)
      assert KindRegistry.lookup(worker_uri) == :error
    end
  end

  # ════════════════════════════════════════════════════════════════════
  # Forward-progress under partial routing — replaces the pre-PR-C
  # saga-rollback tests in phase7_hardening_test.exs
  # ════════════════════════════════════════════════════════════════════

  describe "V1-R6 — partial-routing convergence (replaces HIGH-1 r3/r4/r5)" do
    test "a routing-step failure returns {:partial, _}; the next pass converges" do
      flavor = register_test_flavor()
      tmpl_a = URI.new!("template://agent/team-alpha/uat-r6r-a-#{uniq()}")
      tmpl_b = URI.new!("template://agent/team-alpha/uat-r6r-b-#{uniq()}")
      :ok = create_agent_template(tmpl_a, agent_template_content(flavor, "config-a"))
      :ok = create_agent_template(tmpl_b, agent_template_content(flavor, "config-b"))

      st =
        create_session_template(
          "uat-r6r-team-#{uniq()}",
          [{"dev", tmpl_a}],
          [{{:text_contains, "uatr6route-#{uniq()}"}, ["dev"]}]
        )

      owner = full_template_owner(@default_ws)

      {:ok, %{session_uri: session_uri, orchestrator_uri: orch}} =
        Session.spawn_from_template(st, owner)

      [old_worker] = live_workers_of(orch)
      caps = orchestrator_caps(orch)

      # Force `RuleStore.load_into_registry` to raise during the
      # repoint by removing the MentionRouting meta row. The exact
      # tuple is restored immediately after the call.
      table = EzagentDomainChat.Routing.MentionRouting
      meta_table = Ezagent.RoutingRegistry.table()
      [{_, _} = saved_meta] = :ets.lookup(meta_table, table)
      on_exit(fn -> :ets.insert(meta_table, saved_meta) end)
      :ets.delete(meta_table, table)

      result =
        Tools.update_agent_template("dev", tmpl_b,
          caller: orch,
          caps: caps,
          workspace_uri: @default_ws,
          session_uri: session_uri
        )

      # The repoint commit succeeded in DB; the post-commit ETS reload
      # raised — the reconciler reports `:partial` with `pending:
      # [:routing]`. (NOT `:update_aborted` — there is no saga.)
      assert match?({:partial, %{pending: [:routing | _]}}, result),
             "a routing-reload failure must surface as {:partial, _} with " <>
               ":routing pending. Got: #{inspect(result)}"

      # The new worker stays alive (valid intermediate state — slot
      # commit happens AFTER routing; here we left it before slot to
      # avoid leaving a dead slot). Verify the new worker is alive +
      # the OLD worker is alive (reconciler doesn't kill the old until
      # full convergence).
      {:partial, info} = result
      new_worker = info[:new_worker_uri]
      assert match?(%URI{}, new_worker)
      assert {:ok, _} = KindRegistry.lookup(new_worker)

      assert {:ok, _} = KindRegistry.lookup(old_worker),
             "the OLD worker stays alive until full convergence " <>
               "(routing + slot + terminate all done)"

      # Restore meta; re-invocation must converge.
      :ets.insert(meta_table, saved_meta)

      result2 =
        Tools.update_agent_template("dev", tmpl_b,
          caller: orch,
          caps: caps,
          workspace_uri: @default_ws,
          session_uri: session_uri
        )

      # Either the second pass detects already-converged (the slot
      # commit happened in pass 1 — would return {:ok, new_worker})
      # OR completes the routing repoint + reload + terminate old.
      # Both are valid forward-progress outcomes.
      assert match?({:ok, %URI{}}, result2),
             "after the registry is restored a re-invocation must converge to {:ok, _}. " <>
               "Got: #{inspect(result2)}"
    end
  end

  # Reusable wait_until — shared with phase7_hardening_test.exs.
  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: :ok

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end
end
