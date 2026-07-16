defmodule EzagentDomainInstanceMessage.Invariants.TemplateForkLineageTest do
  @moduledoc """
  Invariant gate (Allen 2026-05-24 PR1) — fork is a GENERIC
  `Ezagent.ActionSet.Template` concern, not a Kind-specific feature. Any
  Template Kind that lists `ActionSet.Template` in its `behaviors/0` MUST
  produce a fork whose `parent_template_uri` points back at the source.

  Specifically asserts:

  - **AgentTemplate fork lineage** — `AgentTemplate.fork/3` returns a NEW
    `template://agent/<ws>/<new_name>` URI; its `:template` slice carries
    `parent_template_uri == parent_uri`.
  - **SessionTemplate fork lineage** — same invariant via
    `SessionTemplate.fork/3` (regression — the lift-to-ActionSet preserved
    the existing contract).
  - **Cap denial — AgentTemplate** — a caller with no AgentTemplate cap
    is denied with `:unauthorized` via dispatch CapBAC.
  - **Parent immutability** — fork never mutates the parent's slice.

  Companion to `docs/runbook/common-failures.md:147-161` (the runbook
  references this gate as `template_fork_lineage_test.exs` — formerly a
  SessionTemplate-only deliverable, now generalized).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Invocation, KindRegistry, SpawnRegistry}
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Entity.{AgentTemplate, SessionTemplate, User}

  @workspace_uri URI.new!("workspace://team-alpha")

  defp uniq, do: System.unique_integer([:positive])

  defp supervisor_for(%URI{} = uri) do
    case Ezagent.URI.type(uri) do
      {:ok, "agent"} -> EzagentDomainInstanceMessage.AgentTemplateSupervisor
      {:ok, "session"} -> EzagentDomainInstanceMessage.SessionTemplateSupervisor
    end
  end

  defp track(uri) do
    on_exit(fn ->
      case KindRegistry.lookup(uri) do
        {:ok, pid} ->
          if Process.alive?(pid) do
            DynamicSupervisor.terminate_child(supervisor_for(uri), pid)
          end

        :error ->
          :ok
      end
    end)
  end

  # Build + persist an AgentTemplate at a fresh URI; return the URI.
  defp persist_agent_template(name) do
    uri = URI.new!("template://team-alpha/agent/#{name}")
    uri_str = URI.to_string(uri)
    :ok = KindSnapshot.delete(uri_str)
    {:ok, _pid} = SpawnRegistry.spawn(uri)
    track(uri)

    content = %{
      name: name,
      description: "fork-lineage parent",
      flavor: "cc",
      project_cwd: "/tmp/proj",
      config_dir: nil,
      settings_path: nil,
      mcp_config_path: nil,
      api_key_helper: nil,
      default_caps: [],
      parent_template_uri: nil,
      created_by: User.admin_uri(),
      created_at: ~U[2026-05-24 00:00:00Z]
    }

    {:ok, _} = dispatch_admin(uri, "template.write", %{content: content})
    {uri, content}
  end

  defp persist_session_parent(name) do
    content = %{
      name: name,
      description: "fork-lineage session parent",
      agent_slots: [],
      routing_rules: [],
      orchestrator_template_uri: Ezagent.URI.new!("template://system/agent/cc-orchestrator"),
      default_workspace_uri: @workspace_uri,
      parent_template_uri: nil,
      version_tag: nil,
      created_by: User.admin_uri(),
      created_at: ~U[2026-05-24 00:00:00Z]
    }

    hash = SessionTemplate.compute_version_hash(content)
    uri = SessionTemplate.build_uri(name, hash, workspace: "team-alpha")
    :ok = KindSnapshot.delete(URI.to_string(uri))
    {:ok, uri} = SessionTemplate.persist_version(content, "team-alpha")
    track(uri)
    {uri, content}
  end

  defp read_content(uri) do
    {:ok, %{content: content}} = dispatch_admin(uri, "template.read", %{})
    content
  end

  defp dispatch_admin(uri, action, args) do
    target = Ezagent.URI.new!("#{URI.to_string(uri)}?action=#{action}")
    admin = User.admin_uri()
    cap = Ezagent.Test.CapHelper.signed_action_cap!(target, admin)

    Invocation.dispatch(%Invocation{
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

  defp fork_cap(parent_uri, caller) do
    parent_uri
    |> Ezagent.URI.with_action(:template, :fork)
    |> Ezagent.Test.CapHelper.signed_action_cap!(caller)
  end

  defp spawn_owner(caps) do
    owner_uri = Ezagent.URI.new!("entity://team-alpha/user/fl-owner-#{uniq()}")

    {:ok, _pid} =
      Ezagent.Kind.spawn(User, %{uri: owner_uri, initial_caps: MapSet.new(caps)})

    on_exit(fn -> KindRegistry.lookup(owner_uri) end)
    owner_uri
  end

  describe "AgentTemplate fork lineage (PR1 — fork lifted to ActionSet.Template)" do
    test "fork records parent_template_uri = the parent's URI" do
      {parent_uri, parent_content} = persist_agent_template("at-fl-parent-#{uniq()}")
      owner_uri = spawn_owner([])
      cap = fork_cap(parent_uri, owner_uri)

      new_name = "at-fl-fork-#{uniq()}"

      assert {:ok, fork_uri} =
               AgentTemplate.fork(parent_uri, new_name,
                 caps: [cap],
                 caller: owner_uri
               )

      track(fork_uri)

      # New Kind at a versionless URI — distinct from the parent.
      assert URI.to_string(fork_uri) == "template://team-alpha/agent/#{new_name}"
      refute fork_uri == parent_uri

      fork_content = read_content(fork_uri)

      assert fork_content.parent_template_uri == parent_uri,
             "fork must carry parent_template_uri == parent URI"

      assert fork_content.name == new_name
      assert fork_content.created_by == owner_uri

      # Parent immutability — the original template's slice is unchanged.
      assert read_content(parent_uri) == parent_content
    end

    test "fork without an AgentTemplate cap → unauthorized" do
      {parent_uri, _content} = persist_agent_template("at-fl-deny-parent-#{uniq()}")
      owner_uri = spawn_owner([])

      assert {:error, reason} =
               AgentTemplate.fork(parent_uri, "at-fl-deny-fork-#{uniq()}",
                 caps: [],
                 caller: owner_uri
               )

      assert reason == :missing_cap,
             "dispatch CapBAC must deny a caller with no AgentTemplate cap " <>
               "(got #{inspect(reason)})"
    end

    test "fork copies content but resets created_at to fork time" do
      {parent_uri, parent_content} = persist_agent_template("at-fl-copy-parent-#{uniq()}")
      owner_uri = spawn_owner([])
      cap = fork_cap(parent_uri, owner_uri)

      before = DateTime.utc_now()

      assert {:ok, fork_uri} =
               AgentTemplate.fork(parent_uri, "at-fl-copy-fork-#{uniq()}",
                 caps: [cap],
                 caller: owner_uri
               )

      track(fork_uri)

      fork_content = read_content(fork_uri)

      # Copy preserved fields
      assert fork_content.description == parent_content.description
      assert fork_content.flavor == parent_content.flavor
      assert fork_content.project_cwd == parent_content.project_cwd

      # Refreshed fields
      assert DateTime.compare(fork_content.created_at, before) in [:gt, :eq]
    end

    test "fork notifies the fork-owner when owner is a user URI (med-batch MED-3)" do
      # `ActionSet.Template.fork_agent_template/3` MUST surface a
      # `:agent_template_forked` notification to the fork-owner so the
      # user who initiated the fork learns about the new template's URI.
      # Gated by user_uri?/1 — agent-owned forks generate no
      # notification (consistent with Workspace.add_member precedent).
      {parent_uri, _content} = persist_agent_template("at-fl-notify-parent-#{uniq()}")
      owner_uri = spawn_owner([])
      cap = fork_cap(parent_uri, owner_uri)

      :ok = Ezagent.Notifications.subscribe(owner_uri)

      new_name = "at-fl-notify-fork-#{uniq()}"

      assert {:ok, fork_uri} =
               AgentTemplate.fork(parent_uri, new_name,
                 caps: [cap],
                 caller: owner_uri
               )

      track(fork_uri)

      assert_receive {:notification, ^owner_uri,
                      %{
                        type: :agent_template_forked,
                        body: %{
                          text: _,
                          parent_template_uri: ^parent_uri,
                          new_template_uri: ^fork_uri
                        },
                        source: Ezagent.ActionSet.Template
                      }},
                     1_000
    end
  end

  describe "SessionTemplate fork lineage (PR1 regression — shim through ActionSet)" do
    test "fork still records parent_template_uri = the parent's hash URI" do
      {parent_uri, _} = persist_session_parent("st-fl-parent-#{uniq()}")

      owner_uri = spawn_owner([])
      session_cap = fork_cap(parent_uri, owner_uri)

      assert {:ok, fork_uri} =
               SessionTemplate.fork(parent_uri, "st-fl-fork-#{uniq()}",
                 caps: [session_cap],
                 caller: owner_uri
               )

      track(fork_uri)

      refute fork_uri == parent_uri
      fork_content = read_content(fork_uri)
      assert fork_content.parent_template_uri == parent_uri
    end
  end
end
