defmodule Ezagent.Behavior.OrchestratorToolsTest do
  @moduledoc """
  The O-4 INVARIANT gate (decomposition spec §3.4 / O-4,
  `feedback_completion_requires_invariant_test`).

  Proves the property the PR-8 rework exists to enforce:

  > A `tools/call` forwarded with ONLY the orchestrator's caller URI (NO
  > ambient / plugin-minted authority) still authorizes correctly via the
  > session-side `OrchestratorTools` action — which reconstructs the
  > orchestrator's delegated caps SESSION-side — AND a forward CLAIMING a
  > caller that is NOT this session's orchestrator is DENIED.

  This drives `Ezagent.Invocation.dispatch` at the
  `session://…?action=orchestrate.<tool>` seam EXACTLY as the cc transport
  (`Ezagent.Orchestrator.McpServer`) does — `ctx.caller = orchestrator_uri`,
  `ctx.caps = MapSet.new()`. No cc module is involved: the authority is
  reconstructed entirely from session-domain data (the live `:chat`
  working-copy + the orchestrator's own `:identity` slice).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Capability
  alias Ezagent.Entity.{Agent, Session, User}

  defp uniq, do: System.unique_integer([:positive])

  @workspace_uri URI.new!("workspace://team-alpha")

  # Spawn a Session + bind workspace + set the durable working-copy
  # orchestrator_uri (the structural authority the action checks).
  defp spawn_orchestrated_session(orchestrator_uri) do
    session_uri = Ezagent.URI.session("team-alpha", "generic", "o4-#{uniq()}")

    {:ok, _pid} =
      Ezagent.Kind.spawn(Session, %{
        uri: session_uri,
        behaviors: Ezagent.Entity.Session.behaviors()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, @workspace_uri)

    {:ok, _} =
      Ezagent.Behavior.Session.ConfigActions.system_set_working_copy(session_uri, %{
        orchestrator_uri: orchestrator_uri,
        orchestrator_template_uri: Ezagent.URI.new!("template://system/agent/cc-orchestrator")
      })

    session_uri
  end

  # Spawn an orchestrator Agent whose `:identity` slice carries `caps` — the
  # session action reconstructs them via the privileged `identity.list_caps`
  # read (NEVER from the wire).
  defp spawn_orchestrator_with_caps(caps) do
    orchestrator_uri = Ezagent.URI.new!("entity://team-alpha/agent/cc_orch-o4-#{uniq()}")
    :ok = Ezagent.AgentFlavorAttributes.put(orchestrator_uri, "cc")
    on_exit(fn -> Ezagent.AgentFlavorAttributes.delete(orchestrator_uri) end)

    {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: orchestrator_uri, initial_caps: caps})
    :ok = Ezagent.WorkspaceRegistry.bind(orchestrator_uri, @workspace_uri)
    orchestrator_uri
  end

  defp template_cap(kind) do
    %Capability{
      kind: kind,
      behavior: Ezagent.Behavior.Template,
      instance: {:within_workspace, @workspace_uri},
      workspace_uri: @workspace_uri,
      granted_by: User.admin_uri(),
      granted_at: DateTime.utc_now()
    }
  end

  # Forward a `tools/call` EXACTLY as the cc transport does — ctx.caller is
  # the (claimed) orchestrator URI, ctx.caps is EMPTY. Returns the dispatched
  # action's raw result (`{:ok, {:ok, _} | {:error, _}}`) or a dispatch error.
  defp forward(session_uri, claimed_caller, tool, arguments) do
    target = Ezagent.URI.with_action(session_uri, :orchestrate, tool)

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: target,
      mode: :call,
      args: %{arguments: arguments},
      ctx: %{
        caller: claimed_caller,
        caps: MapSet.new(),
        reply: {:caller_inbox, self()}
      }
    })
  end

  describe "O-4 — caps reconstructed session-side from the caller URI alone" do
    test "a forward carrying ONLY the orchestrator caller URI authorizes via reconstruction" do
      # The orchestrator's OWN identity slice holds the :agent_template cap
      # (cap #4) — and NOTHING crosses the wire. list_templates needs cap #4.
      orchestrator_uri = spawn_orchestrator_with_caps(MapSet.new([template_cap(:agent_template)]))
      session_uri = spawn_orchestrated_session(orchestrator_uri)

      # An AgentTemplate in the workspace so the list is non-trivially gated.
      at_uri = URI.new!("template://team-alpha/agent/o4-at-#{uniq()}")
      seed_agent_template(at_uri)

      # Forward with ZERO caps in ctx — the session action reconstructs the
      # orchestrator's cap #4 from its identity slice and authorizes.
      assert {:ok, {:ok, structured}} =
               forward(session_uri, orchestrator_uri, :list_templates, %{}),
             "a forward with ONLY the caller URI (no caps on the wire) MUST authorize via " <>
               "session-side cap reconstruction — that is O-4."

      assert URI.to_string(at_uri) in Enum.map(structured.agent_templates, &to_string/1)

      # And the per-kind gating is the orchestrator's OWN cap, not ambient:
      # it holds only cap #4 → session_templates gated out.
      assert structured.session_templates == [],
             "the reconstructed authority is the orchestrator's OWN delegated cap set " <>
               "(cap #4 only) — NOT ambient admin_caps. session_templates must be gated out."
    end

    test "a forward with NO delegated caps in the orchestrator's slice DENIES (no admin fallback)" do
      # The orchestrator's identity slice is EMPTY — reconstruction yields an
      # empty cap set, so list_templates (needs cap #3/#4) must DENY. If the
      # op fell back to ambient admin_caps this would succeed; it must NOT.
      orchestrator_uri = spawn_orchestrator_with_caps(MapSet.new())
      session_uri = spawn_orchestrated_session(orchestrator_uri)

      assert {:ok, {:error, :unauthorized}} =
               forward(session_uri, orchestrator_uri, :list_templates, %{})
    end
  end

  describe "O-4 — structural caller-is-our-orchestrator gate" do
    test "a forward CLAIMING a caller that is NOT this session's orchestrator is DENIED" do
      # The real orchestrator holds cap #4; a DIFFERENT agent (not the
      # session's orchestrator) forwards the same tool. Even though that other
      # agent might itself hold caps, the STRUCTURAL gate denies: ctx.caller
      # MUST equal the session's working-copy orchestrator_uri.
      orchestrator_uri = spawn_orchestrator_with_caps(MapSet.new([template_cap(:agent_template)]))
      session_uri = spawn_orchestrated_session(orchestrator_uri)

      impostor = spawn_orchestrator_with_caps(MapSet.new([template_cap(:agent_template)]))

      assert {:ok, {:error, :unauthorized}} =
               forward(session_uri, impostor, :list_templates, %{}),
             "a caller that is NOT the session's stored orchestrator MUST be denied — the " <>
               "structural caller-is-our-orchestrator gate is the entry authority (O-4)."
    end

    test "a forward against a session with NO orchestrator is DENIED" do
      # A plain session whose working copy has no orchestrator_uri. Any caller
      # claiming to drive its orchestrate tools fails the structural gate.
      session_uri = Ezagent.URI.session("team-alpha", "generic", "o4-plain-#{uniq()}")

      {:ok, _pid} =
        Ezagent.Kind.spawn(Session, %{
          uri: session_uri,
          behaviors: Ezagent.Entity.Session.behaviors()
        })

      :ok = Ezagent.WorkspaceRegistry.bind(session_uri, @workspace_uri)

      caller = spawn_orchestrator_with_caps(MapSet.new([template_cap(:agent_template)]))

      assert {:ok, {:error, :unauthorized}} =
               forward(session_uri, caller, :list_templates, %{})
    end
  end

  # --- helpers -----------------------------------------------------------

  defp seed_agent_template(uri) do
    flavor = "o4flavor#{uniq()}"

    :ok =
      Ezagent.AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Agent,
        template_class: Ezagent.Behavior.OrchestratorToolsTest.SeedClass
      })

    content = %{
      name: "o4-worker",
      description: "o4 worker",
      flavor: flavor,
      project_cwd: "/tmp/o4",
      config_dir: nil,
      settings_path: nil,
      mcp_config_path: nil,
      api_key_helper: nil,
      default_caps: [],
      created_by: User.admin_uri(),
      created_at: ~U[2026-06-01 00:00:00Z]
    }

    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)

    target = Ezagent.URI.new!("#{URI.to_string(uri)}?action=template.write")

    {:ok, _} =
      Ezagent.Invocation.dispatch(%Ezagent.Invocation{
        target: target,
        mode: :call,
        args: %{content: content},
        ctx: %{
          caller: User.admin_uri(),
          caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
          reply: {:caller_inbox, self()}
        }
      })

    :ok
  end

  defmodule SeedClass do
    @moduledoc false
    @behaviour Ezagent.Kind.Template

    @impl true
    def template_name, do: "o4.seed.agent"

    @impl true
    def validate(tmpl) when is_map(tmpl), do: :ok
    def validate(_), do: {:error, :not_a_map}

    @impl true
    def instantiate(_n, %{"agent_uri" => uri_str}, _ws) do
      agent_uri = Ezagent.URI.new!(uri_str)

      case Ezagent.SpawnRegistry.spawn_detailed(agent_uri) do
        {:ok, :started, _pid} -> {:ok, [agent_uri], %{fresh?: true}}
        {:ok, :already_started, _pid} -> {:ok, [agent_uri], %{fresh?: false}}
        {:error, _} = err -> err
      end
    end

    def instantiate(_n, tmpl, _ws), do: {:error, {:invalid_template, tmpl}}
  end
end
