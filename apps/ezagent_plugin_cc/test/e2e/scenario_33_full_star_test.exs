defmodule EzagentDomainInstanceMessage.E2E.Scenario33_FullStarTest do
  @moduledoc """
  E2E Scenario 33 — full-star: the orchestrator dispatches a worker of
  EACH agent flavor (`docs/scenarios/33-full-star-orchestrator-all-flavors`).

  This is the **deterministic invariant gate** (the scenario's
  Verification tier 1). It proves the orchestrator can compose a team of
  THREE DISTINCT flavors — the `cc` / `codex` / `curl` matrix Scenario 33
  targets — via its `add_managed_member` MCP tool (team-routing-unification
  §3.8 retired the slot tools): each worker is spawned, recorded under THIS
  orchestrator's lineage (so cap #2 authorizes managing it), and joined as
  a distinct session MEMBER with a stable `role_name`. All three coexist +
  route independently (`define_rule_set_rule`).

  Per the scenario doc, the automated tier "may stub the provider call
  where a live provider isn't available in CI": the three flavors here
  are no-PTY synthetic stand-ins (the worker Kind is the plain
  `Ezagent.Entity.Agent`), exactly as the sibling
  `orchestrator_mcp_e2e_test` does for a single flavor. What this pins is
  the orchestrator's per-flavor SLOT/spawn/lineage machinery — flavor
  count = 3, distinct flavor names, distinct slots — NOT the real
  cc/codex/curl PTY+provider round-trip.

  The real cc/codex/curl PTY + provider reply + Feishu-group mirror is
  the scenario's **LIVE tier** (the true gate, Standard 3 in
  `feedback_esr_e2e_standards`): it requires the cc/codex/curl worker
  AgentTemplates seeded + live provider creds, and a real `@orch` Feishu
  message whose round-trip is visible in the bound group. That tier is
  NOT this CI test (see the scenario doc's "Provider prerequisites").
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{AgentFlavorRegistry, AgentLineage, ActionSet, KindRegistry}
  alias Ezagent.Entity.{Agent, Session, User}
  alias Ezagent.Session.SessionManager
  alias Ezagent.AgentBridge.TokenStore
  alias Ezagent.Orchestrator.McpServer

  @moduletag scenario: "33-full-star-orchestrator-all-flavors"

  @workspace_uri URI.new!("workspace://team-alpha")

  # Transport #53 Decision C — the tool ops run in the per-orchestrator
  # `SessionManager` GenServer. Isolate TokenStore in a sandboxed EZAGENT_HOME.
  setup do
    reset_workspace!()
    home = Path.join(System.tmp_dir!(), "s33-home-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    prev_home = System.get_env("EZAGENT_HOME")
    System.put_env("EZAGENT_HOME", home)

    on_exit(fn ->
      if prev_home,
        do: System.put_env("EZAGENT_HOME", prev_home),
        else: System.delete_env("EZAGENT_HOME")

      File.rm_rf(home)
    end)

    :ok
  end

  # A no-PTY Template Class: the worker Kind is the plain Agent (no
  # claude/codex/curl subprocess). Mirrors orchestrator_mcp_e2e_test's
  # TestFlavorClass. `instantiate/3` reports the real freshness signal
  # from the atomic spawn (update_agent_template's swap depends on it).
  defmodule StubFlavorClass do
    @moduledoc false
    @behaviour Ezagent.Kind.Template

    @impl true
    def template_name, do: "scenario33.stub.agent"

    @impl true
    def validate(tmpl) when is_map(tmpl),
      do: if(Map.has_key?(tmpl, "agent_uri"), do: :ok, else: {:error, :missing_agent_uri})

    def validate(_), do: {:error, :not_a_map}

    @impl true
    def instantiate(_tmpl_name, %{"agent_uri" => uri_str}, _workspace_uri) do
      agent_uri = Ezagent.URI.new!(uri_str)

      case Ezagent.SpawnRegistry.spawn_detailed(agent_uri) do
        {:ok, :started, _pid} -> {:ok, [agent_uri], %{fresh?: true}}
        {:ok, :already_started, _pid} -> {:ok, [agent_uri], %{fresh?: false}}
        {:error, _} = err -> err
      end
    end

    def instantiate(_n, tmpl, _ws), do: {:error, {:invalid_template, tmpl}}
  end

  defp uniq, do: System.unique_integer([:positive])

  # Register a synthetic flavor standing in for one of the real
  # cc/codex/curl flavors (so the test exercises the per-flavor slot
  # machinery without a real provider). The flavor name is the `<flavor>`
  # prefix the worker URI carries.
  defp register_stub_flavor(label) do
    flavor = "s33#{label}#{uniq()}"

    :ok =
      AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Agent,
        template_class: StubFlavorClass
      })

    flavor
  end

  defp dispatch(uri, action, args) do
    target = Ezagent.URI.new!("#{URI.to_string(uri)}?action=#{action}")
    admin = User.admin_uri()
    cap = Ezagent.Test.CapHelper.signed_action_cap!(target, admin)

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: args,
      ctx: %{
        caller: admin,
        caps: MapSet.new([cap]),
        reply: {:caller_inbox, self()}
      }
    })
  end

  defp create_agent_template(uri, flavor, name) do
    content = %{
      name: name,
      description: "scenario33 worker #{name}",
      flavor: flavor,
      project_cwd: "/tmp/scenario33",
      config_dir: nil,
      settings_path: nil,
      mcp_config_path: nil,
      api_key_helper: nil,
      default_caps: [],
      created_by: User.admin_uri(),
      created_at: ~U[2026-06-01 00:00:00Z]
    }

    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
    {:ok, %{content: ^content}} = dispatch(uri, "template.write", %{content: content})
    :ok
  end

  defp spawn_session do
    ensure_workspace()
    session_uri = Ezagent.URI.session("team-alpha", "generic", "s33-#{uniq()}")

    {:ok, _pid} =
      Ezagent.Kind.spawn(Session, %{
        uri: session_uri,
        behaviors: Ezagent.Entity.Session.behaviors(),
        owner_uri: User.admin_uri()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, @workspace_uri)
    session_uri
  end

  defp ensure_workspace do
    case Ezagent.Workspace.create("team-alpha", %{}) do
      {:ok, _} -> :ok
      {:error, :workspace_exists} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp reset_workspace! do
    _ = Ezagent.Kind.terminate(@workspace_uri)
    :ok = Ezagent.SnapshotStore.delete(@workspace_uri)
    _ = Ezagent.Workspace.Store.delete("team-alpha")
    {:ok, _} = Ezagent.Workspace.create("team-alpha", %{})
    :ok
  end

  # Transport #53 Decision C — spawn the orchestrator WITH its delegated caps in
  # its `:identity` slice (reconstructed session-side per-call), set the durable
  # working-copy orchestrator_uri (the structural gate), mint its bridge token,
  # and start the per-orchestrator `SessionManager`. Returns `{orchestrator_uri,
  # token}`.
  defp spawn_orchestrator(session_uri) do
    orchestrator_uri = Ezagent.URI.new!("entity://team-alpha/agent/cc_orch-s33-#{uniq()}")
    :ok = Ezagent.AgentFlavorAttributes.put(orchestrator_uri, "cc")

    on_exit(fn ->
      Ezagent.AgentFlavorAttributes.delete(orchestrator_uri)
    end)

    {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: orchestrator_uri, initial_caps: MapSet.new()})
    :ok = Ezagent.WorkspaceRegistry.bind(orchestrator_uri, @workspace_uri)

    :ok =
      Ezagent.Entity.Session.Orchestrator.Caps.grant_orchestrator_scoped_caps(
        orchestrator_uri,
        session_uri,
        User.admin_uri()
      )

    join_target = Ezagent.URI.with_action(session_uri, :session, :join)
    join_cap = Ezagent.Test.CapHelper.signed_action_cap!(join_target, User.admin_uri())

    :ok =
      Ezagent.Orchestrator.Tools.join_member(
        session_uri,
        orchestrator_uri,
        %{role_name: "orchestrator", in_session_template: true},
        User.admin_uri(),
        MapSet.new([join_cap])
      )

    epoch = Ecto.UUID.generate()

    {:ok, _} =
      Ezagent.ActionSet.Session.ConfigActions.system_set_working_copy(session_uri, %{
        orchestrator_uri: %{
          uri: orchestrator_uri,
          epoch: epoch,
          status: :active
        },
        orchestrator_materialization_epoch: epoch
      })

    {:ok, token} = TokenStore.mint(orchestrator_uri)

    {:ok, _sm} =
      SessionManager.ensure_started(
        orchestrator_uri: orchestrator_uri,
        session_uri: session_uri,
        workspace_uri: @workspace_uri,
        owner_uri: orchestrator_uri
      )

    on_exit(fn -> SessionManager.stop(orchestrator_uri) end)

    {orchestrator_uri, token}
  end

  # Run a tool through the per-orchestrator SessionManager (the real Decision C
  # flow: token verify → structural gate → cap reconstruction → Tools op).
  # Returns the RAW `{:ok, _}` / `{:error, _}` result.
  defp run_tool(%{orchestrator_uri: orch, token: token}, tool, args) when is_binary(tool) do
    SessionManager.run_tool(orch, tool, args, token)
  end

  defp chat_slice(session_uri) do
    {:ok, pid} = KindRegistry.lookup(session_uri)
    %{state: %{session: %{state: slice}}} = :sys.get_state(pid)
    slice
  end

  describe "orchestrator composes a 3-flavor team (cc + codex + curl stand-ins)" do
    setup do
      # Three DISTINCT flavors standing in for cc / codex / curl.
      flavors = %{
        cc: register_stub_flavor("cc"),
        codex: register_stub_flavor("codex"),
        curl: register_stub_flavor("curl")
      }

      templates =
        Map.new(flavors, fn {label, flavor} ->
          uri = URI.new!("template://team-alpha/agent/s33-#{label}-#{uniq()}")
          :ok = create_agent_template(uri, flavor, "worker-#{label}")
          {label, uri}
        end)

      session_uri = spawn_session()
      {orchestrator_uri, token} = spawn_orchestrator(session_uri)

      mcp = %{orchestrator_uri: orchestrator_uri, token: token, session_uri: session_uri}

      %{
        mcp: mcp,
        session_uri: session_uri,
        orchestrator_uri: orchestrator_uri,
        templates: templates
      }
    end

    test "add_managed_member spawns one member per flavor, each under the orchestrator lineage",
         ctx do
      members = [
        {"worker-cc", ctx.templates.cc},
        {"worker-codex", ctx.templates.codex},
        {"worker-ds", ctx.templates.curl}
      ]

      member_uris =
        for {role_name, tmpl_uri} <- members do
          result =
            run_tool(ctx.mcp, "add_managed_member", %{
              "source_agent_template_uri" => URI.to_string(tmpl_uri),
              "role_name" => role_name
            })

          assert {:ok, %URI{} = member_uri} = result,
                 "add_managed_member #{role_name} failed: #{inspect(result)}"

          assert AgentLineage.spawned_in_lineage?(member_uri, ctx.orchestrator_uri),
                 "#{role_name} member must be recorded under the orchestrator lineage (cap #2)"

          {role_name, member_uri}
        end

      # All THREE members coexist in the session, each carrying its role_name
      # — the full-star team, one member per flavor.
      slice = chat_slice(ctx.session_uri)

      for {role_name, _} <- members do
        assert ActionSet.Session.role_name_to_uri(slice.members, role_name),
               "member #{role_name} must be a live session member — got #{inspect(Map.keys(slice.members))}"
      end

      # The three members are distinct entities.
      uris = Enum.map(member_uris, fn {_, u} -> URI.to_string(u) end)

      assert length(Enum.uniq(uris)) == 3,
             "the three flavor members must be distinct: #{inspect(uris)}"
    end

    # E2E coverage gap that let the #750 structuredContent bug escape: the tests
    # above call `run_tool/` (SessionManager.run_tool) directly and assert the
    # RAW `{:ok, %URI{}}` — they BYPASS the cc transport's MCP encode boundary
    # (`McpServer.handle_tool_call` → `to_mcp_result`), which is where the bug
    # lived. This test drives a URI-returning tool (add_managed_member) through
    # that encode boundary and asserts the response is a VALID MCP result: a
    # real MCP client (claude) requires `structuredContent` to be an OBJECT, and
    # pre-fix the URI stringified to a bare string → "expected record, received
    # string" → the orchestrator could not read back the member URI. (Found in
    # prod only by Allen's manual Feishu test, 2026-06-15.)
    test "add_managed_member through the cc MCP transport encodes a VALID object structuredContent (#750 regression)",
         ctx do
      raw =
        run_tool(ctx.mcp, "add_managed_member", %{
          "source_agent_template_uri" => URI.to_string(ctx.templates.cc),
          "role_name" => "worker-mcp-encode"
        })

      assert {:ok, %URI{}} = raw, "add_managed_member must succeed: #{inspect(raw)}"

      # The encode boundary the live transport (`handle_tool_call`) applies.
      encoded = McpServer.to_mcp_result(raw)

      refute encoded["isError"]

      assert is_map(encoded["structuredContent"]),
             "MCP structuredContent MUST be an object/record, not a bare string " <>
               "(pre-#750-fix a {:ok, member_uri} encoded to a string → the bridge " <>
               "rejected it) — got: #{inspect(encoded["structuredContent"])}"

      assert is_binary(encoded["structuredContent"]["result"]) and
               encoded["structuredContent"]["result"] =~ "entity://",
             "the new member URI must be readable back from structuredContent.result"
    end

    test "define_rule_set_rule routes to each flavor member independently", ctx do
      for {role_name, tmpl_uri} <- [
            {"wm-cc", ctx.templates.cc},
            {"wm-codex", ctx.templates.codex},
            {"wm-ds", ctx.templates.curl}
          ] do
        add =
          run_tool(ctx.mcp, "add_managed_member", %{
            "source_agent_template_uri" => URI.to_string(tmpl_uri),
            "role_name" => role_name
          })

        assert {:ok, _} = add, "add_managed_member #{role_name} failed: #{inspect(add)}"

        wm =
          run_tool(ctx.mcp, "define_rule_set_rule", %{
            "matcher_ast" => %{"type" => "text_contains", "arg" => role_name},
            "receiver_role_name" => role_name,
            "rule_set" => "rs-#{role_name}"
          })

        assert {:ok, %{id: id}} = wm,
               "define_rule_set_rule for #{role_name} failed: #{inspect(wm)}"

        assert is_integer(id)
      end
    end
  end
end
