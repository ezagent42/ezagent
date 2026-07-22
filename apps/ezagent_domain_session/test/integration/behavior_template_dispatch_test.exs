defmodule EzagentDomainInstanceMessage.Integration.BehaviorTemplateDispatchTest do
  @moduledoc """
  Phase 7 completion PR-1 (SPEC §1.0 + §1.2) — `Ezagent.ActionSet.Template`
  exercised through the production dispatch path.

  Drives `Ezagent.Invocation.dispatch/1` against real spawned Template
  Kinds — no mocks — and asserts:

  - both Template Kinds resolve `template.read` / `template.write` /
    `template.instantiate` through `BehaviorRegistry`;
  - `:write` then `:read` round-trips the `:template` content slice;
  - `:write` on a `{:snapshot, :on_change}` Template Kind writes a
    `kind_snapshots` row;
  - `cap_for_action(AgentTemplate, :write, uri)` yields
    `behavior == Ezagent.ActionSet.Template`, `kind == :agent_template`;
  - SessionTemplate `:write` is write-once: a second divergent write →
    `:immutable_version`; a hash-mismatched write → `:hash_mismatch`;
  - SessionTemplate `:instantiate` → `{:error, :use_generator}`;
  - a 3-segment template URI round-trips through the snapshot;
  - cross-workspace template names do not collide.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{BehaviorRegistry, Capability, Invocation, KindRegistry}
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Entity.{AgentTemplate, SessionTemplate, User}

  defp uniq, do: System.unique_integer([:positive])

  # Each Template Kind lives under its own DynamicSupervisor. Terminate
  # through the supervisor synchronously at test end (NOT a bare
  # Process.exit in on_exit) so the Kind is gone before the next test's
  # sandbox owner is established — otherwise a lingering Kind's snapshot
  # read hits a connection whose owner has exited.
  defp supervisor_for(%URI{} = uri) do
    case Ezagent.URI.type(uri) do
      {:ok, "agent"} -> EzagentDomainInstanceMessage.AgentTemplateSupervisor
      {:ok, "session"} -> EzagentDomainInstanceMessage.SessionTemplateSupervisor
    end
  end

  defp spawn_template(uri) do
    {:ok, pid} = Ezagent.SpawnRegistry.spawn(uri)
    sup = supervisor_for(uri)

    on_exit(fn ->
      if Process.alive?(pid) do
        DynamicSupervisor.terminate_child(sup, pid)
      end

      wait_until(fn -> KindRegistry.lookup(uri) == :error end)
    end)

    pid
  end

  defp wait_until(fun, attempts \\ 50)
  defp wait_until(_fun, 0), do: :ok

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end

  defp dispatch(uri, action, args) do
    target = URI.new!("#{URI.to_string(uri)}?action=#{action}")
    admin = User.admin_uri()
    cap = Ezagent.Test.CapHelper.signed_action_cap!(target, admin)

    Invocation.dispatch(%Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: args,
      ctx: %{
        caller: admin,
        authenticated_principal: admin,
        caps: MapSet.new([cap]),
        reply: {:caller_inbox, self()}
      }
    })
  end

  defp agent_content do
    %{
      name: "cc-orch",
      description: "orchestrator",
      flavor: "cc",
      project_cwd: "/tmp/proj",
      config_dir: nil,
      settings_path: nil,
      mcp_config_path: nil,
      api_key_helper: nil,
      default_caps: [],
      created_by: Ezagent.URI.new!("entity://team-alpha/user/admin"),
      created_at: ~U[2026-05-22 00:00:00Z]
    }
  end

  defp session_content do
    %{
      name: "code-review",
      description: "team",
      agent_slots: [],
      routing_rules: [],
      orchestrator_template_uri: Ezagent.URI.new!("template://system/agent/cc-orchestrator"),
      default_workspace_uri: Ezagent.URI.new!("workspace://team-alpha"),
      parent_template_uri: nil,
      version_tag: nil,
      created_by: Ezagent.URI.new!("entity://team-alpha/user/admin"),
      created_at: ~U[2026-05-22 00:00:00Z]
    }
  end

  describe "BehaviorRegistry resolution" do
    test "both Template Kinds resolve all 3 actions to Ezagent.ActionSet.Template" do
      for kind <- [AgentTemplate, SessionTemplate], action <- [:read, :write, :instantiate] do
        assert {:ok, Ezagent.ActionSet.Template} = BehaviorRegistry.lookup(kind, action),
               "#{inspect(kind)} must resolve #{action} → Ezagent.ActionSet.Template"
      end
    end
  end

  describe "cap_for_action/3" do
    test "AgentTemplate :write derives behavior == Ezagent.ActionSet.Template, kind :agent_template" do
      uri = URI.new!("template://team-alpha/agent/cap-probe-#{uniq()}")
      needed = Capability.cap_for_action(AgentTemplate, :write, uri)

      assert needed.behavior == Ezagent.ActionSet.Template
      assert needed.kind == :agent_template
    end
  end

  describe "AgentTemplate — :write then :read round-trip + snapshot" do
    test "a dispatched :write populates the slice, :read returns it, and a kind_snapshots row exists" do
      uri = URI.new!("template://team-alpha/agent/at-rt-#{uniq()}")
      uri_str = URI.to_string(uri)
      :ok = KindSnapshot.delete(uri_str)

      _pid = spawn_template(uri)
      content = agent_content()

      assert {:ok, %{content: ^content}} = dispatch(uri, "template.write", %{content: content})
      assert {:ok, %{content: ^content}} = dispatch(uri, "template.read", %{})

      # {:snapshot, :on_change} — the :write slice mutation wrote a row.
      assert %KindSnapshot{kind_type: "agent_template"} = KindSnapshot.get(uri_str)
    end
  end

  describe "SessionTemplate — write-once + hash-checked through dispatch" do
    test "first :write succeeds when the URI hash matches; an idempotent retry no-ops" do
      content = session_content()
      hash = SessionTemplate.compute_version_hash(content)
      name = "st-imm-#{uniq()}"
      uri = SessionTemplate.build_uri(name, hash, workspace: "team-alpha")
      :ok = KindSnapshot.delete(URI.to_string(uri))

      _pid = spawn_template(uri)

      assert {:ok, %{content: ^content}} = dispatch(uri, "template.write", %{content: content})

      # An idempotent retry (identical content) no-ops as success — the
      # write-once Kind is not corrupted.
      assert {:ok, %{content: ^content}} = dispatch(uri, "template.write", %{content: content})
      assert {:ok, %{content: ^content}} = dispatch(uri, "template.read", %{})
    end

    test "a divergent :write to a hash-addressed URI → :hash_mismatch (write-once defense)" do
      content = session_content()
      hash = SessionTemplate.compute_version_hash(content)
      uri = SessionTemplate.build_uri("st-div-#{uniq()}", hash, workspace: "team-alpha")
      :ok = KindSnapshot.delete(URI.to_string(uri))

      _pid = spawn_template(uri)
      assert {:ok, _} = dispatch(uri, "template.write", %{content: content})

      # A divergent write to the SAME hash-addressed Kind: the divergent
      # content hashes differently, so the URI ↔ content hash check
      # rejects it — a stray retry cannot corrupt the version in place.
      divergent = %{content | description: "tampered"}
      assert {:error, :hash_mismatch} = dispatch(uri, "template.write", %{content: divergent})

      # The slice is unchanged.
      assert {:ok, %{content: ^content}} = dispatch(uri, "template.read", %{})
    end

    test "a hash-mismatched :write into a fresh Kind → :hash_mismatch" do
      content = session_content()
      # Build the Kind at a URI whose @<hash> belongs to DIFFERENT content.
      wrong_hash = SessionTemplate.compute_version_hash(%{content | description: "other"})
      uri = SessionTemplate.build_uri("st-hm-#{uniq()}", wrong_hash, workspace: "team-alpha")
      :ok = KindSnapshot.delete(URI.to_string(uri))

      _pid = spawn_template(uri)

      assert {:error, :hash_mismatch} = dispatch(uri, "template.write", %{content: content})
    end

    test "SessionTemplate :instantiate → {:error, :use_generator}" do
      content = session_content()
      hash = SessionTemplate.compute_version_hash(content)
      uri = SessionTemplate.build_uri("st-inst-#{uniq()}", hash, workspace: "team-alpha")
      :ok = KindSnapshot.delete(URI.to_string(uri))

      _pid = spawn_template(uri)
      assert {:error, :use_generator} = dispatch(uri, "template.instantiate", %{})
    end
  end

  describe "3-segment URI round-trip + cross-workspace non-collision (SPEC §1.2)" do
    test "a 3-segment AgentTemplate URI round-trips through the snapshot" do
      uri = URI.new!("template://team-alpha/agent/3seg-#{uniq()}")
      uri_str = URI.to_string(uri)
      :ok = KindSnapshot.delete(uri_str)

      _pid = spawn_template(uri)
      content = agent_content()
      assert {:ok, _} = dispatch(uri, "template.write", %{content: content})

      row = KindSnapshot.get(uri_str)
      assert row.uri == uri_str
      assert row.workspace_uri == "workspace://team-alpha"
    end

    test "the same template name in two workspaces are distinct Kinds (no collision)" do
      name = "shared-name-#{uniq()}"
      # Same template NAME, two DISTINCT workspaces (default vs
      # team-alpha) — the 3-segment per-tenant URI scopes them to
      # separate Kinds. (Both legs previously read `team-alpha`, so
      # `uri_a == uri_b` collapsed to one Kind and the cross-leak the
      # test guards against could never be observed.)
      uri_a = URI.new!("template://default/agent/#{name}")
      uri_b = URI.new!("template://team-alpha/agent/#{name}")
      :ok = KindSnapshot.delete(URI.to_string(uri_a))
      :ok = KindSnapshot.delete(URI.to_string(uri_b))

      _pid_a = spawn_template(uri_a)
      _pid_b = spawn_template(uri_b)

      content_a = %{agent_content() | description: "in default"}
      content_b = %{agent_content() | description: "in team-alpha"}

      assert {:ok, _} = dispatch(uri_a, "template.write", %{content: content_a})
      assert {:ok, _} = dispatch(uri_b, "template.write", %{content: content_b})

      # Each workspace's template keeps its OWN content — no cross-leak.
      assert {:ok, %{content: %{description: "in default"}}} =
               dispatch(uri_a, "template.read", %{})

      assert {:ok, %{content: %{description: "in team-alpha"}}} =
               dispatch(uri_b, "template.read", %{})
    end
  end
end
