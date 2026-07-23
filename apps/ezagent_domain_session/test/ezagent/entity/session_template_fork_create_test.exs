defmodule Ezagent.Entity.SessionTemplateForkCreateTest do
  @moduledoc """
  Phase 7 completion PR-6 (SPEC §2 PR-6) — the two session-creation
  entry points `Ezagent.Entity.SessionTemplate.fork/3` and
  `Ezagent.Entity.SessionTemplate.create/3`.

  Both wrap `persist_version/2` + the §1.7 (e) owner-cap grant, and both
  require a `ActionSet.Template` `:session_template` cap as a preflight
  (§1.4). Covers:

  - **fork lineage** — the forked template's `parent_template_uri`
    points at the exact `parent_uri@<hash>` it forked from, AND the
    parent template row is unchanged (immutable — `fork` never
    `:write`s the parent);
  - **create produces a root** — `parent_template_uri: nil`;
  - **cap denial** — a caller without the SessionTemplate template cap
    → `{:error, :unauthorized}` on each of `fork`/`create`;
  - the §1.7 (e) owner-cap grant lands on the owner's User Kind.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{ActionSet, Invocation, Identity, KindRegistry}
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Entity.{SessionTemplate, User}

  defp uniq, do: System.unique_integer([:positive])

  # Terminate Kinds spawned during a test so the next test's sandbox is
  # clean. SessionTemplate Kinds live under SessionTemplateSupervisor;
  # User Kinds under the identity supervisor — for the latter a simple
  # cleanup-on-exit is enough since they are URI-unique per test.
  defp track_session_template(uri) do
    on_exit(fn ->
      case KindRegistry.lookup(uri) do
        {:ok, pid} ->
          if Process.alive?(pid) do
            DynamicSupervisor.terminate_child(
              EzagentDomainInstanceMessage.SessionTemplateSupervisor,
              pid
            )
          end

        :error ->
          :ok
      end
    end)
  end

  # A SessionTemplate `:template` content map.
  defp session_content(name, opts) do
    %{
      name: name,
      description: Keyword.get(opts, :description, "a team"),
      agent_slots: Keyword.get(opts, :agent_slots, []),
      routing_rules: Keyword.get(opts, :routing_rules, []),
      orchestrator_template_uri: Ezagent.URI.new!("template://system/agent/cc-orchestrator"),
      default_workspace_uri: Ezagent.URI.new!("workspace://team-alpha"),
      parent_template_uri: Keyword.get(opts, :parent_template_uri),
      version_tag: nil,
      created_by: User.admin_uri(),
      created_at: ~U[2026-05-22 00:00:00Z]
    }
  end

  # Persist a parent SessionTemplate and return its hash URI.
  defp persist_parent(name, opts \\ []) do
    content = session_content(name, opts)
    hash = SessionTemplate.compute_version_hash(content)

    :ok =
      KindSnapshot.delete(
        URI.to_string(SessionTemplate.build_uri(name, hash, workspace: "team-alpha"))
      )

    {:ok, uri} = SessionTemplate.persist_version(content, "team-alpha")
    track_session_template(uri)
    uri
  end

  # Read a SessionTemplate's `:template` content via the dispatch :read.
  defp read_content(uri) do
    target = Ezagent.URI.new!("#{URI.to_string(uri)}?action=template.read")
    admin = User.admin_uri()
    cap = Ezagent.Test.CapHelper.signed_action_cap!(target, admin)

    {:ok, %{content: content}} =
      Invocation.dispatch(%Invocation{
        origin: :trusted_internal,
        target: target,
        mode: :call,
        args: %{},
        ctx: %{
          caller: admin,
          authenticated_principal: admin,
          caps: MapSet.new([cap]),
          reply: {:caller_inbox, self()}
        }
      })

    content
  end

  defp fork_cap(parent_uri, caller) do
    parent_uri
    |> Ezagent.URI.with_action(:template, :fork)
    |> Ezagent.Test.CapHelper.signed_action_cap!(caller)
  end

  defp create_owner_and_cap do
    workspace = "fc-create-ws-#{uniq()}"
    workspace_uri = Ezagent.URI.workspace(workspace)
    {:ok, _pid} = Ezagent.Workspace.spawn_workspace(workspace, %{})
    :ok = Ezagent.ReadyGate.await(workspace_uri, 2_000)
    owner = spawn_owner([], workspace)

    cap =
      workspace_uri
      |> Ezagent.URI.with_action(:workspace, :write_session_templates)
      |> Ezagent.Test.CapHelper.signed_action_cap!(owner)

    {owner, workspace, cap}
  end

  # Spawn a User Kind at a unique URI carrying exactly `caps`.
  defp spawn_owner(caps, workspace \\ "team-alpha") do
    owner_uri = Ezagent.URI.new!("entity://#{workspace}/user/fc-owner-#{uniq()}")
    {:ok, _pid} = Ezagent.Kind.spawn(User, %{uri: owner_uri, initial_caps: MapSet.new(caps)})
    on_exit(fn -> KindRegistry.lookup(owner_uri) end)
    owner_uri
  end

  describe "fork/3 — lineage + parent immutability (SPEC §2 PR-6)" do
    test "the fork records parent_template_uri = the parent's hash URI" do
      parent_uri = persist_parent("fc-parent-#{uniq()}")
      owner_uri = spawn_owner([])
      cap = fork_cap(parent_uri, owner_uri)

      assert {:ok, fork_uri} =
               SessionTemplate.fork(parent_uri, "fc-fork-#{uniq()}",
                 caps: [cap],
                 caller: owner_uri
               )

      track_session_template(fork_uri)

      # The fork is a DISTINCT Kind at its own hash URI.
      refute fork_uri == parent_uri

      fork_content = read_content(fork_uri)
      assert fork_content.parent_template_uri == parent_uri
    end

    test "the fork copies the parent's CONFIG (description); agent_slots is NOT persisted (codex MINOR / PR-8)" do
      parent_uri =
        persist_parent("fc-cfg-parent-#{uniq()}",
          description: "the original team",
          agent_slots: [{"backend", Ezagent.URI.new!("template://team-alpha/agent/be")}]
        )

      owner_uri = spawn_owner([])
      cap = fork_cap(parent_uri, owner_uri)

      assert {:ok, fork_uri} =
               SessionTemplate.fork(parent_uri, "fc-cfg-fork-#{uniq()}",
                 caps: [cap],
                 caller: owner_uri
               )

      track_session_template(fork_uri)
      fork_content = read_content(fork_uri)

      assert fork_content.description == "the original team"

      # `agent_slots` is stripped at persistence (codex MINOR) — the parent
      # never durably stored it, so the fork cannot carry it either.
      refute Map.has_key?(fork_content, :agent_slots)
      refute Map.has_key?(fork_content, "agent_slots")
    end

    test "the parent template row is UNCHANGED after a fork (immutable)" do
      parent_name = "fc-immut-parent-#{uniq()}"
      parent_uri = persist_parent(parent_name, description: "do not touch")

      parent_before = read_content(parent_uri)
      parent_snapshot_before = KindSnapshot.get(URI.to_string(parent_uri))

      owner_uri = spawn_owner([])
      cap = fork_cap(parent_uri, owner_uri)

      assert {:ok, fork_uri} =
               SessionTemplate.fork(parent_uri, "fc-immut-fork-#{uniq()}",
                 caps: [cap],
                 caller: owner_uri
               )

      track_session_template(fork_uri)

      # The parent's content slice + its snapshot row are byte-identical.
      assert read_content(parent_uri) == parent_before
      assert read_content(parent_uri).parent_template_uri == nil

      parent_snapshot_after = KindSnapshot.get(URI.to_string(parent_uri))
      assert parent_snapshot_after.state_binary == parent_snapshot_before.state_binary
    end

    test "fork stamps a fresh created_by (the caller)" do
      parent_uri = persist_parent("fc-by-parent-#{uniq()}")
      owner_uri = spawn_owner([])
      cap = fork_cap(parent_uri, owner_uri)

      assert {:ok, fork_uri} =
               SessionTemplate.fork(parent_uri, "fc-by-fork-#{uniq()}",
                 caps: [cap],
                 caller: owner_uri
               )

      track_session_template(fork_uri)
      assert read_content(fork_uri).created_by == owner_uri
    end
  end

  describe "create/3 — produces a ROOT template (SPEC §2 PR-6)" do
    test "create makes a template with parent_template_uri: nil" do
      {owner_uri, workspace, cap} = create_owner_and_cap()

      assert {:ok, root_uri} =
               SessionTemplate.create("fc-root-#{uniq()}", %{description: "a fresh root"},
                 caps: [cap],
                 caller: owner_uri,
                 workspace: workspace
               )

      track_session_template(root_uri)

      content = read_content(root_uri)
      assert content.parent_template_uri == nil
      assert content.description == "a fresh root"
    end

    test "create forces parent_template_uri to nil even if config supplies one" do
      {owner_uri, workspace, cap} = create_owner_and_cap()

      # A root never has a parent — a `parent_template_uri` in the
      # config is overridden to nil.
      assert {:ok, root_uri} =
               SessionTemplate.create(
                 "fc-root-noparent-#{uniq()}",
                 %{
                   parent_template_uri:
                     Ezagent.URI.new!("template://team-alpha/session/sneaky@abc")
                 },
                 caps: [cap],
                 caller: owner_uri,
                 workspace: workspace
               )

      track_session_template(root_uri)
      assert read_content(root_uri).parent_template_uri == nil
    end

    test "create accepts string-keyed config (JSON-boundary shape)" do
      {owner_uri, workspace, cap} = create_owner_and_cap()

      assert {:ok, root_uri} =
               SessionTemplate.create(
                 "fc-root-strkeys-#{uniq()}",
                 %{"description" => "string-keyed config"},
                 caps: [cap],
                 caller: owner_uri,
                 workspace: workspace
               )

      track_session_template(root_uri)
      assert read_content(root_uri).description == "string-keyed config"
    end
  end

  describe "cap preflight — denial on each path (SPEC §1.4 / §2 PR-6)" do
    test "fork without a SessionTemplate template cap → {:error, :unauthorized}" do
      parent_uri = persist_parent("fc-deny-parent-#{uniq()}")
      # An owner whose User Kind holds NO template cap.
      owner_uri = spawn_owner([])

      assert {:error, :missing_cap} =
               SessionTemplate.fork(parent_uri, "fc-deny-fork-#{uniq()}",
                 caps: [],
                 caller: owner_uri
               )
    end

    test "create without a SessionTemplate template cap → {:error, :unauthorized}" do
      owner_uri = spawn_owner([])

      assert {:error, :unauthorized} =
               SessionTemplate.create("fc-deny-root-#{uniq()}", %{},
                 caps: [],
                 caller: owner_uri,
                 workspace: "team-alpha"
               )
    end

    test "an unauthorized fork does NOT mutate the parent" do
      parent_uri = persist_parent("fc-deny-immut-#{uniq()}")
      parent_before = read_content(parent_uri)
      owner_uri = spawn_owner([])

      assert {:error, :missing_cap} =
               SessionTemplate.fork(parent_uri, "fc-deny-immut-fork-#{uniq()}",
                 caps: [],
                 caller: owner_uri
               )

      # The cap preflight runs BEFORE any read/persist — the parent is
      # untouched.
      assert read_content(parent_uri) == parent_before
    end

    test "a MapSet of caps is accepted (not only a list)" do
      parent_uri = persist_parent("fc-mapset-parent-#{uniq()}")
      owner_uri = spawn_owner([])
      cap = fork_cap(parent_uri, owner_uri)

      assert {:ok, fork_uri} =
               SessionTemplate.fork(parent_uri, "fc-mapset-fork-#{uniq()}",
                 caps: MapSet.new([cap]),
                 caller: owner_uri
               )

      track_session_template(fork_uri)
    end
  end

  describe "owner-cap grant (SPEC §1.7 (e))" do
    test "fork grants the owner a ActionSet.Template SessionTemplate cap" do
      parent_uri = persist_parent("fc-grant-parent-#{uniq()}")
      owner_uri = spawn_owner([])
      cap = fork_cap(parent_uri, owner_uri)

      assert {:ok, fork_uri} =
               SessionTemplate.fork(parent_uri, "fc-grant-fork-#{uniq()}",
                 caps: [cap],
                 caller: owner_uri
               )

      track_session_template(fork_uri)

      # The owner's User Kind now carries a SessionTemplate template cap
      # — the Generator's owner-cap preflight (§1.4) would pass for it.
      owner_caps = Identity.list_caps_for(owner_uri)

      assert Enum.any?(owner_caps, fn cap ->
               cap.kind == :session_template and cap.behavior == ActionSet.Template and
                 cap.instance == fork_uri and valid_for?(cap, fork_uri, owner_uri)
             end),
             "fork must grant the owner a ActionSet.Template :session_template cap (§1.7 (e))"
    end

    test "create grants the owner a ActionSet.Template SessionTemplate cap" do
      {owner_uri, workspace, cap} = create_owner_and_cap()

      assert {:ok, root_uri} =
               SessionTemplate.create("fc-grant-root-#{uniq()}", %{},
                 caps: [cap],
                 caller: owner_uri,
                 workspace: workspace
               )

      track_session_template(root_uri)

      owner_caps = Identity.list_caps_for(owner_uri)

      assert Enum.any?(owner_caps, fn cap ->
               cap.kind == :session_template and cap.behavior == ActionSet.Template and
                 cap.instance == root_uri and valid_for?(cap, root_uri, owner_uri)
             end),
             "create must grant the owner a ActionSet.Template :session_template cap (§1.7 (e))"
    end
  end

  defp valid_for?(cap, target, presenter) do
    {:ok, authority} = Ezagent.Cap.Authority.open(target, :session_template)
    Ezagent.Cap.Authority.verify(authority, cap, presenter)
  end
end
