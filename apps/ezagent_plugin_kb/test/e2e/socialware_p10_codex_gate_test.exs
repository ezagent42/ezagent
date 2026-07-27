defmodule EzagentPluginKb.E2E.SocialwareP10CodexGateTest do
  @moduledoc """
  P10 socialware lifecycle gate.

  This is intentionally in-process: form authoring goes through the world
  action handler, session creation goes through Workspace.create_session/3,
  customer ingress goes through AnonAdmission + session.send, and the
  deterministic codex-orchestrator leg calls kb_query through the real
  AgentBridge token -> SessionManager seam. Only final answer wording is canned.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Capability, Invocation, Message, MessageStore, Workspace}
  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.AgentBridge.TokenStore
  alias Ezagent.ActionSet.KindBase
  alias Ezagent.Entity.User
  alias Ezagent.Session.SessionManager
  alias Ezagent.Socialware.{AnonAdmission, DefinitionRegistry, Installation}
  alias Ezagent.World.{ConversationData, WorkspacePluginActions}
  alias EzagentPluginCodex.BridgeAdapter

  @seed Path.expand("../../../../scripts/autoservice_tier1_seed.exs", __DIR__)

  setup_all do
    Code.require_file(@seed)
    :ok
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_world)
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_codex)
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_native)
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_kb)
    :ok = DefinitionRegistry.seed_builtin_definitions()
    :ok
  end

  @tag :e2e
  @tag :integration
  test "author -> install -> customer -> codex tool loop -> supervisor -> security -> publish policy" do
    ws = "p10-socialware-#{uniq()}"
    workspace_uri = Ezagent.URI.workspace(ws)
    author = Ezagent.URI.user(ws, "author")
    supervisor_a = Ezagent.URI.user(ws, "supervisor-a")
    supervisor_b = Ezagent.URI.user(ws, "supervisor-b")
    stale_supervisor = Ezagent.URI.user(ws, "stale-supervisor")
    bot_recipe = "p10-bot-recipe-#{uniq()}"

    {:ok, _} = Workspace.create(ws, %{})
    :ok = spawn_user(author)
    :ok = grant_workspace_cap(author, workspace_uri, :add_template)
    :ok = spawn_user(supervisor_a)
    :ok = spawn_user(supervisor_b)
    :ok = spawn_user(stale_supervisor)
    :ok = seed_bot_recipe(bot_recipe)

    supervised_template = "p10-supervised-#{uniq()}"
    supervised_app = "#{supervised_template}-app"

    %{template_uri: supervised_template_uri} =
      author_socialware_template(
        workspace_uri,
        author,
        supervised_template,
        supervised_app,
        bot_recipe,
        publish_policy: "supervised"
      )

    assert {:ok, supervised_hash} =
             Ezagent.TemplateTags.resolve(workspace_uri, supervised_template, "current")

    assert supervised_hash == template_hash(supervised_template_uri)

    assert {:ok, definition, object} = DefinitionRegistry.lookup(workspace_uri, supervised_app)
    assert [%{role_name: "bot", fill: :agent, recipe: ^bot_recipe}] = definition.roles
    assert [%{"adapter_id" => "web_feed"}] = definition.adapters

    assert definition.visibility_policy == %{
             scope: :private,
             publish_policy: :supervised,
             web_anon_access: true
           }

    assert is_binary(object.id)

    {:ok, %{session_uri: session_uri}} =
      Workspace.create_session(
        workspace_uri,
        %{short_name: "customer-#{uniq()}", template_name: supervised_template},
        admin_ctx(workspace_uri)
      )

    on_exit(fn -> cleanup_session(session_uri) end)

    assert Installation.installed?(session_uri, supervised_app)

    {:ok, kind_base} = Ezagent.Kind.read(session_uri, :kind_base, spawn: :never)
    behaviors = KindBase.behaviors_in_slice(kind_base)
    assert Ezagent.ActionSet.Session in behaviors
    assert Ezagent.ActionSet.Turn in behaviors
    assert Ezagent.ActionSet.Surface in behaviors
    assert Ezagent.ActionSet.SupervisorApproval in behaviors

    {:ok, %{anon_uri: anon_uri}} = AnonAdmission.admit_anonymous_participant(session_uri)
    :ok = dispatch_send(anon_uri, session_uri, "Need the tier-one hotline")
    assert wait_until(fn -> recent_text?(session_uri, "Need the tier-one hotline") end)
    assert wait_until(fn -> match?(%URI{}, role_member_uri(session_uri, "bot")) end)
    bot_uri = role_member_uri(session_uri, "bot")

    assert route_targets_role?(anon_uri, session_uri, bot_uri)

    {:ok, kb_seed} =
      autoservice_seed(:seed,
        ws: ws,
        register_recipes: true,
        kb_agent: "kb-p10-#{uniq()}",
        kb_flavor: "kb-native-p10-#{uniq()}",
        autoservice_agent: "autoservice-p10-#{uniq()}",
        autoservice_flavor: "autosvc-p10-#{uniq()}",
        autoservice_role: "autosvc-role-p10-#{uniq()}"
      )

    orchestrator =
      start_codex_orchestrator(
        workspace_uri,
        session_uri,
        supervised_template_uri,
        kb_seed.kb_agent_uri
      )

    held_caps = Ezagent.Identity.read_entity_caps(orchestrator.uri)

    assert Enum.any?(held_caps, fn cap ->
             cap.behavior == Ezagent.ActionSet.Kb and cap.action == :query
           end),
           "the Session-Config principal must durably hold kb.query before tool dispatch"

    tool_result =
      run_codex_tool(orchestrator, "kb_query", %{
        "kb_agent" => kb_seed.kb_agent_name,
        "query" => autoservice_seed(:kb_probe_query),
        "k" => 5
      })

    assert %{"ok" => true, "result" => %{"hits" => hits}} = tool_result
    fact = autoservice_seed(:kb_fact_token)
    assert Enum.any?(hits, &(Map.get(&1, "text", "") =~ fact))

    answer = "KB says #{fact}; supervisor can review this deterministic codex reply."

    assert :ok =
             BridgeAdapter.dispatch_reply(
               orchestrator.uri,
               [URI.to_string(session_uri)],
               answer,
               "p10-ref-#{uniq()}",
               []
             )

    assert wait_until(fn -> recent_text?(session_uri, answer) end)

    {:ok, _} =
      Workspace.assign_role(
        workspace_uri,
        "supervisor",
        supervisor_a,
        %{quorum_policy: "majority"},
        admin_ctx(workspace_uri)
      )

    {:ok, _} =
      Workspace.assign_role(
        workspace_uri,
        "supervisor",
        supervisor_b,
        %{quorum_policy: "majority"},
        admin_ctx(workspace_uri)
      )

    read_cap = read_unfiltered_cap(session_uri, workspace_uri)
    supervisor_caps = Ezagent.Identity.list_caps_for(supervisor_a)
    assert Enum.any?(supervisor_caps, &Capability.matches?(&1, read_cap))

    # S-2: responsibility assignment grants reviewer-membership. The
    # supervisor therefore reaches privileged row policy only after the same
    # current member-cap gate as every other reader.
    assert wait_until(fn ->
             :ok ==
               Ezagent.Session.Membership.authorize(
                 %{},
                 supervisor_a,
                 session_uri,
                 supervisor_a
               )
           end)

    turn =
      compose_supervised_turn(
        session_uri,
        User.admin_uri(),
        lifecycle_caps(session_uri, User.admin_uri(), turn: :open, turn: :compose)
      )

    assert internal_message?(turn.message_id)

    refute "supervised draft" in visible_texts(session_uri, User.admin_uri())
    # The at-join member-cap grant is async; poll until the held-cap gate opens.
    assert wait_until(fn -> "supervised draft" in visible_texts(session_uri, supervisor_a) end)

    assert {:ok, %{status: :pending}} =
             dispatch_call(
               session_uri,
               :supervisor_approval,
               :submit_verdict,
               %{
                 turn_id: turn.turn_id,
                 responsibility: "supervisor",
                 verdict: :approve,
                 quorum_policy: %{type: :majority},
                 arbiter: "arbiter"
               },
               supervisor_a,
               supervisor_caps
             )

    assert {:ok, %{status: :escalated, receiver: {:role, "arbiter"}}} =
             dispatch_call(
               session_uri,
               :supervisor_approval,
               :submit_verdict,
               %{
                 turn_id: turn.turn_id,
                 responsibility: "supervisor",
                 verdict: :reject,
                 quorum_policy: %{type: :majority},
                 arbiter: "arbiter"
               },
               supervisor_b,
               Ezagent.Identity.list_caps_for(supervisor_b)
             )

    assert {:error, :stale_holder} =
             dispatch_call(
               session_uri,
               :supervisor_approval,
               :submit_verdict,
               %{
                 turn_id: turn.turn_id,
                 responsibility: "supervisor",
                 verdict: :approve,
                 quorum_policy: %{type: :any_one},
                 arbiter: nil
               },
               stale_supervisor,
               lifecycle_caps(
                 session_uri,
                 stale_supervisor,
                 supervisor_approval: :submit_verdict
               )
             )

    assert {:ok, %{status: :awaiting_human}} =
             dispatch_call(
               session_uri,
               :turn,
               :claim,
               %{turn_id: turn.turn_id, by: supervisor_a},
               supervisor_a,
               supervisor_caps
             )

    assert {:ok, %{approved: _}} =
             dispatch_call(
               session_uri,
               :surface,
               :approve,
               %{version: turn.version},
               supervisor_a,
               supervisor_caps
             )

    assert {:ok, %{status: :settled}} =
             dispatch_call(
               session_uri,
               :turn,
               :settle,
               %{turn_id: turn.turn_id},
               supervisor_a,
               supervisor_caps
             )

    assert wait_until(fn ->
             "supervised draft" in visible_texts(session_uri, User.admin_uri())
           end)

    auto_template = "p10-auto-#{uniq()}"
    auto_app = "#{auto_template}-app"

    %{template_uri: _auto_template_uri} =
      author_socialware_template(workspace_uri, author, auto_template, auto_app, bot_recipe,
        publish_policy: "auto"
      )

    {:ok, %{session_uri: auto_session}} =
      Workspace.create_session(
        workspace_uri,
        %{short_name: "auto-#{uniq()}", template_name: auto_template},
        admin_ctx(workspace_uri)
      )

    on_exit(fn -> cleanup_session(auto_session) end)

    auto_turn = compose_auto_turn(auto_session, author)
    refute internal_message?(auto_turn.message_id)
    assert "auto reply" in visible_texts(auto_session, User.admin_uri())
  end

  defp author_socialware_template(
         workspace_uri,
         author,
         template_name,
         socialware_name,
         bot_recipe,
         opts
       ) do
    author_ctx = Ezagent.Test.CapHelper.signed_workspace_ctx!(workspace_uri, author)

    {:noreply, socket} =
      WorkspacePluginActions.save_session_template(
        %Phoenix.LiveView.Socket{
          assigns: %{
            __changed__: %{},
            current_entity_uri: author,
            current_workspace_uri: workspace_uri,
            current_caps: author_ctx.caps,
            world_state: %{}
          }
        },
        %{
          "name" => template_name,
          "description" => "P10 socialware #{template_name}",
          "socialware" =>
            socialware_form(socialware_name, Keyword.fetch!(opts, :publish_policy), bot_recipe)
        }
      )

    assert socket.assigns.last_dispatch_status == "ok",
           "form save failed with state #{inspect(socket.assigns.world_state)}"

    template_uri = Ezagent.URI.new!(socket.assigns.world_state["last_template_uri"])

    %{
      template_uri: template_uri,
      socialware_ref: socket.assigns.world_state["last_socialware_ref"]
    }
  end

  defp socialware_form(name, publish_policy, bot_recipe) do
    %{
      "name" => name,
      "bases" => [
        "Ezagent.ActionSet.Session",
        "Ezagent.ActionSet.Publisher.SessionImpl"
      ],
      "shape" => [
        "Ezagent.ActionSet.Turn",
        "Ezagent.ActionSet.Surface",
        "Ezagent.ActionSet.SupervisorApproval"
      ],
      "roles" => [
        %{
          "role_name" => "bot",
          "fill" => "agent",
          "recipe" => bot_recipe,
          "flavor" => "native"
        }
      ],
      "routing_rules" => [
        %{
          "matcher" => %{"type" => "always"},
          "receivers" => ["bot"],
          "rule_set" => "default",
          "position" => 0,
          "prompt_template_ref" => "answer"
        }
      ],
      "prompt_templates" => %{"answer" => "Use the KB context."},
      "legends" => %{
        "support" => %{
          "member_set" => ["bot"],
          "bound_rule_set" => "default",
          "fold" => false
        }
      },
      "adapters" => [
        %{"adapter_id" => "web_feed", "role" => "customer", "config" => %{}}
      ],
      "visibility_policy" => %{
        "publish_policy" => publish_policy,
        "web_anon_access" => true
      }
    }
  end

  defp start_codex_orchestrator(workspace_uri, session_uri, template_uri, kb_agent_uri) do
    orchestrator_uri = Ezagent.URI.agent(workspace_uri.host, "codex-orchestrator-p10-#{uniq()}")
    binding_epoch = Ezagent.Session.OrchestratorBinding.new_epoch()
    :ok = Ezagent.AgentFlavorAttributes.put(orchestrator_uri, "codex")
    on_exit(fn -> Ezagent.AgentFlavorAttributes.delete(orchestrator_uri) end)

    kb_query_target = Ezagent.URI.with_action(kb_agent_uri, :kb, :query)
    session_send_target = Ezagent.URI.with_action(session_uri, :session, :send)

    issued_caps =
      [kb_query_target, session_send_target]
      |> Enum.map(&Ezagent.Test.CapHelper.signed_action_cap!(&1, orchestrator_uri))

    {:ok, _pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
        uri: orchestrator_uri,
        initial_caps: MapSet.new(issued_caps)
      })

    :ok = Ezagent.WorkspaceRegistry.bind(orchestrator_uri, workspace_uri)

    assert {:ok, _} =
             Ezagent.ActionSet.Session.ConfigActions.system_set_working_copy(session_uri, %{
               session_template_uri: template_uri,
               orchestrator_uri:
                 Ezagent.Session.OrchestratorBinding.active(orchestrator_uri, binding_epoch),
               orchestrator_materialization_epoch: binding_epoch,
               orchestrator_template_uri:
                 Ezagent.Orchestrator.CodexOrchestratorSeed.template_uri()
             })

    {:ok, _pid} =
      SessionManager.ensure_started(
        orchestrator_uri: orchestrator_uri,
        session_uri: session_uri,
        workspace_uri: workspace_uri,
        owner_uri: orchestrator_uri,
        parent_template_uri: template_uri
      )

    {:ok, token} = TokenStore.mint(orchestrator_uri)
    on_exit(fn -> SessionManager.stop(orchestrator_uri) end)

    %{uri: orchestrator_uri, token: token}
  end

  defp run_codex_tool(%{uri: orchestrator_uri, token: token}, tool, arguments) do
    socket = %Phoenix.Socket{assigns: %{agent_uri: orchestrator_uri, bridge_token: token}}

    assert {:reply, {:ok, result}, ^socket} =
             BridgeAdapter.handle_client_event(
               "run_tool",
               %{"tool" => tool, "arguments" => arguments},
               socket
             )

    result
  end

  defp compose_supervised_turn(session_uri, caller, caps) do
    assert {:ok, %{turn_id: turn_id}} =
             dispatch_call(
               session_uri,
               :turn,
               :open,
               %{trigger: %{message_id: "p10"}, opened_at: System.system_time(:millisecond)},
               caller,
               caps
             )

    assert {:ok, %{message_ids: [message_id], version: version}} =
             dispatch_call(
               session_uri,
               :turn,
               :compose,
               %{
                 turn_id: turn_id,
                 result_refs: [
                   %{kind: :chat, text: "supervised draft"},
                   %{kind: :page, tree: %{type: "text", props: %{text: "supervised page"}}}
                 ]
               },
               caller,
               caps
             )

    %{turn_id: turn_id, message_id: message_id, version: version}
  end

  defp compose_auto_turn(session_uri, caller) do
    caps = lifecycle_caps(session_uri, caller, turn: :open, turn: :compose)

    assert {:ok, %{turn_id: turn_id}} =
             dispatch_call(
               session_uri,
               :turn,
               :open,
               %{trigger: %{message_id: "p10-auto"}, opened_at: System.system_time(:millisecond)},
               caller,
               caps
             )

    assert {:ok, %{message_ids: [message_id]}} =
             dispatch_call(
               session_uri,
               :turn,
               :compose,
               %{
                 turn_id: turn_id,
                 result_refs: [%{kind: :chat, text: "auto reply"}]
               },
               caller,
               caps
             )

    %{turn_id: turn_id, message_id: message_id}
  end

  defp dispatch_call(session_uri, behavior, action, args, caller, caps) do
    Invocation.dispatch(%Invocation{
      origin: :trusted_internal,
      target: Ezagent.URI.with_action(session_uri, behavior, action),
      mode: :call,
      args: args,
      ctx: %{
        caller: caller,
        authenticated_principal: caller,
        caps: caps,
        reply: {:caller_inbox, self()}
      }
    })
  end

  defp dispatch_send(caller_uri, session_uri, text) do
    msg = Message.new(caller_uri, %{text: text, attachments: []})
    target = Ezagent.URI.with_action(session_uri, :session, :send)

    :ok =
      Invocation.dispatch(%Invocation{
        origin: :trusted_internal,
        target: target,
        mode: :cast,
        args: %{message: msg},
        ctx: %{
          caller: caller_uri,
          authenticated_principal: caller_uri,
          caps: MapSet.new([Ezagent.Test.CapHelper.signed_action_cap!(target, caller_uri)]),
          reply: :ignore
        }
      })
  end

  defp route_targets_role?(sender_uri, session_uri, bot_uri) do
    msg =
      %{
        Message.new(sender_uri, %{text: "routing probe", attachments: []})
        | session_uri: session_uri,
          workspace_uri: URI.to_string(Ezagent.URI.workspace_of(session_uri))
      }

    members = session_member_uris(session_uri)

    Ezagent.Routing.Resolver.resolve(msg, session_uri, members,
      workspace_uri: Ezagent.URI.workspace_of(session_uri),
      role_resolver: fn
        "bot", _ctx -> bot_uri
        _role, _ctx -> nil
      end
    )
    |> Enum.any?(&(URI.to_string(&1) == URI.to_string(bot_uri)))
  end

  defp session_member_uris(session_uri) do
    {:ok, slice} = Ezagent.Kind.read(session_uri, :session, spawn: :never)
    members = get_in(slice, [:state, :members]) || Map.get(slice, :members, %{})
    Map.keys(members)
  end

  defp role_member_uri(session_uri, role_name) do
    {:ok, slice} = Ezagent.Kind.read(session_uri, :session, spawn: :never)
    members = get_in(slice, [:state, :members]) || Map.get(slice, :members, %{})

    Enum.find_value(members, fn {uri, meta} ->
      if Map.get(meta, :role_name) == role_name or Map.get(meta, "role_name") == role_name,
        do: uri
    end)
  end

  # #1464: the :read_unfiltered row-policy is sourced LIVE from the caller's
  # persisted caps (SessionReads.read_unfiltered?/2), NOT a caller-supplied flag.
  # So read AS the principal whose live caps should decide filtering.
  defp visible_texts(session_uri, caller_uri) do
    session_uri
    |> ConversationData.state_for(%{
      caller_uri: caller_uri,
      workspace_uri: Ezagent.URI.workspace_of(session_uri),
      sessions: []
    })
    |> Map.fetch!("messages")
    |> Enum.map(&Map.fetch!(&1, "text"))
  end

  defp recent_text?(session_uri, text) do
    session_uri
    |> MessageStore.recent_in_session(20)
    |> Enum.any?(&message_text?(&1, text))
  end

  defp message_text?(message, text) do
    Map.get(message.body, "text") == text or Map.get(message.body, :text) == text
  end

  defp internal_message?(message_id) do
    {:ok, message} = MessageStore.by_id(message_id)
    message.visibility == :internal
  end

  defp read_unfiltered_cap(session_uri, workspace_uri) do
    Capability.cap(
      :session,
      Ezagent.ActionSet.Session,
      :read_unfiltered,
      session_uri,
      workspace_uri
    )
  end

  defp spawn_user(uri) do
    case Ezagent.Kind.spawn(User, %{uri: uri}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp seed_bot_recipe(name) do
    RecipeRegistry.invalidate(RecipeRegistry.system_workspace_uri(), name)

    case RecipeRegistry.seed_role_if_absent(%{
           name: name,
           requested_caps: [%{behavior: Ezagent.ActionSet.Identity, action: :list_caps}],
           skills: []
         }) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp grant_workspace_cap(holder, workspace_uri, action) do
    cap =
      Capability.cap(
        :workspace,
        Ezagent.ActionSet.Workspace,
        action,
        workspace_uri,
        workspace_uri
      )

    Ezagent.Identity.Grant.grant_cap(holder, cap, {:admin, User.admin_uri()})
  end

  defp cleanup_session(session_uri) do
    SessionManager.ensure_for_session(session_uri)

    case Ezagent.KindRegistry.lookup(session_uri) do
      {:ok, pid} when is_pid(pid) ->
        if Process.alive?(pid) do
          DynamicSupervisor.terminate_child(EzagentDomainInstanceMessage.SessionSupervisor, pid)
        end

      :error ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp admin_ctx(workspace_uri) do
    Ezagent.Test.CapHelper.signed_workspace_ctx!(workspace_uri, User.admin_uri())
  end

  defp lifecycle_caps(session_uri, caller, actions) when is_list(actions) do
    actions
    |> Enum.flat_map(fn {behavior, action} ->
      target = Ezagent.URI.with_action(session_uri, behavior, action)
      Ezagent.Socialware.TestCapHelper.lifecycle_caps(session_uri, caller, target)
    end)
    |> MapSet.new()
  end

  defp autoservice_seed(fun), do: apply(Ezagent.AutoService.Tier1Seed, fun, [])
  defp autoservice_seed(fun, arg), do: apply(Ezagent.AutoService.Tier1Seed, fun, [arg])

  defp template_hash(%URI{} = uri) do
    uri |> Ezagent.URI.name!() |> String.split("@", parts: 2) |> List.last()
  end

  defp uniq, do: System.unique_integer([:positive])

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end
end
