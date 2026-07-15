defmodule Ezagent.Domain.AgentTest do
  @moduledoc """
  V1 acceptance fix (2026-05-21) — `Ezagent.Domain.Agent` is the
  flavor-agnostic facade Domain UI uses to ask "what's the
  lifecycle status of this agent URI?". This test pins the public
  contract.

  ## Why this matters (Allen's Q3)

  Pre-fix, `AgentDetailLive.load_status/1` directly called
  `Ezagent.Domain.Pty.lookup` (originally `Ezagent.PluginCc.PtyServer.find_by_agent_uri`
  pre-Domain.Pty-PR-A) — a Domain UI importing Plugin internals. Per `ezagent-developer` skill
  invariant 8 (plugin authoring contract), Domain UI MUST NOT
  import Plugin module functions. `Ezagent.Domain.Agent
  .lifecycle_status/1` is the sanctioned boundary: it
  derives the agent flavor prefix for display and detects PTY-backed
  runtime by asking `Ezagent.Domain.Pty.alive?/1`, unifying the
  response shape across flavors.

  ## Contract

  Return shape: `%{phase, flavor, detail}` where
  - `phase` ∈ `[:alive, :registered, :not_found, :error, :instantiated]`
  - `flavor` is `String.t() | nil` (cc / echo / curl / nil for
    non-agent URIs)
  - `detail` is plugin-specific map or `nil`

  ## What's verified

  - any flavor + alive Kind + PtyServer running → `:alive` with
    PTY detail (os_pid, cwd, etc.)
  - any flavor + alive Kind without PtyServer → `:alive` with empty
    detail map
  - Unregistered URI with stored flavor → `:not_found` with that
    stored flavor (so UI can render "echo agent does not exist"
    vs just "agent does not exist")
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Domain.Agent, SpawnRegistry}

  setup do
    Ezagent.UriQuery.init()
    previous = :ets.lookup(Ezagent.UriQuery.table(), :flavor)

    on_exit(fn ->
      :ets.delete(Ezagent.UriQuery.table(), :flavor)

      for entry <- previous do
        :ets.insert(Ezagent.UriQuery.table(), entry)
      end
    end)

    :ok
  end

  describe "lifecycle_status/1 — stored flavor lookup" do
    test "reads flavor from UriQuery for prefixless agent URIs" do
      cc_uri = Ezagent.URI.new!("entity://team-alpha/agent/unregistered-cc-#{u()}")
      echo_uri = Ezagent.URI.new!("entity://team-alpha/agent/unregistered-echo-#{u()}")
      curl_uri = Ezagent.URI.new!("entity://team-alpha/agent/unregistered-curl-#{u()}")
      put_flavors(%{cc_uri => "cc", echo_uri => "echo", curl_uri => "curl"})

      assert %{phase: :not_found, flavor: "cc", detail: nil} =
               Agent.lifecycle_status(cc_uri)

      assert %{phase: :not_found, flavor: "echo", detail: nil} =
               Agent.lifecycle_status(echo_uri)

      assert %{phase: :not_found, flavor: "curl", detail: nil} =
               Agent.lifecycle_status(curl_uri)
    end

    test "returns nil flavor when UriQuery has no stored flavor" do
      not_an_agent = Ezagent.URI.new!("entity://team-alpha/user/admin")
      workspace = Ezagent.URI.new!("workspace://team-alpha")

      assert %{phase: :not_found, flavor: nil, detail: nil} =
               Agent.lifecycle_status(not_an_agent)

      assert %{phase: :not_found, flavor: nil, detail: nil} =
               Agent.lifecycle_status(workspace)
    end
  end

  describe "lifecycle_status/1 — py flavor (alive Kind, no PTY layer)" do
    test "alive py Kind returns %{phase: :alive, flavor: \"py\", detail: %{}}" do
      py_uri = Ezagent.URI.new!("entity://team-alpha/agent/py_lifecycle-#{u()}")
      put_flavors(%{py_uri => "py"})

      # Spawn the py Kind via the standardized SpawnRegistry path (chat's
      # entity:// spawn fn → spawn_agent/1 → flavor resolver). The PyAgent Kind
      # comes up alive WITHOUT a uv subprocess: with no installed script,
      # `Behavior.PyAgent.activate/2` skips the subprocess re-spawn (so this
      # stays a fast, non-uv lifecycle assertion).
      {:ok, pid} = SpawnRegistry.spawn(py_uri)
      assert is_pid(pid) and Process.alive?(pid)

      assert %{phase: :alive, flavor: "py", detail: %{}} =
               Agent.lifecycle_status(py_uri)
    end
  end

  describe "lifecycle_status/1 — PTY detection is flavor-agnostic" do
    test "alive cc Kind without PtyServer returns :alive with empty detail" do
      cc_uri = Ezagent.URI.new!("entity://team-alpha/agent/cc_lifecycle-#{u()}")
      put_flavors(%{cc_uri => "cc"})

      {:ok, pid} = SpawnRegistry.spawn(cc_uri)
      assert is_pid(pid) and Process.alive?(pid)

      assert %{phase: :alive, flavor: "cc", detail: %{}} =
               Agent.lifecycle_status(cc_uri)
    end

    test "alive curl and future-flavor Kinds without PtyServer return :alive with empty detail" do
      curl_uri = Ezagent.URI.new!("entity://team-alpha/agent/curl_lifecycle-#{u()}")
      future_uri = Ezagent.URI.new!("entity://team-alpha/agent/future_lifecycle-#{u()}")
      put_flavors(%{curl_uri => "curl", future_uri => "future"})

      {:ok, curl_pid} = Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: curl_uri})
      {:ok, future_pid} = Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: future_uri})

      assert is_pid(curl_pid) and Process.alive?(curl_pid)
      assert is_pid(future_pid) and Process.alive?(future_pid)

      assert %{phase: :alive, flavor: "curl", detail: %{}} =
               Agent.lifecycle_status(curl_uri)

      assert %{phase: :alive, flavor: "future", detail: %{}} =
               Agent.lifecycle_status(future_uri)
    end

    test "codex-flavored Kind with live PtyServer returns PTY detail without a codex clause" do
      codex_uri = Ezagent.URI.new!("entity://team-alpha/agent/codex_lifecycle-#{u()}")
      put_flavors(%{codex_uri => "codex"})

      {:ok, agent_pid} = Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: codex_uri})
      {:ok, pty_pid} = Ezagent.Domain.Pty.start(codex_uri, %{cwd: "/tmp", test_mode: true})

      on_exit(fn ->
        if Process.alive?(pty_pid), do: Ezagent.Domain.Pty.stop(codex_uri)
      end)

      assert is_pid(agent_pid) and Process.alive?(agent_pid)
      assert is_pid(pty_pid) and Process.alive?(pty_pid)

      Process.sleep(50)

      result = Agent.lifecycle_status(codex_uri)

      assert %{phase: :alive, flavor: "codex"} = result
      assert is_map(result.detail)
      assert result.detail.agent_uri == codex_uri
      assert result.detail.cwd == "/tmp"
      assert result.detail.test_mode == true
      assert result.detail.running == true
    end
  end

  describe "lifecycle_status/1 — unregistered URI" do
    test "non-existent agent URI returns :not_found with stored flavor" do
      cc_uri = Ezagent.URI.new!("entity://team-alpha/agent/does-not-exist-#{u()}")
      put_flavors(%{cc_uri => "cc"})

      assert %{phase: :not_found, flavor: "cc", detail: nil} =
               Agent.lifecycle_status(cc_uri)
    end
  end

  describe "ensure_deliverable/1" do
    test "returns not_created for an Agent URI with no durable state" do
      agent_uri = Ezagent.URI.new!("entity://team-alpha/agent/never-created-#{u()}")

      assert {:error, :not_created} = Agent.ensure_deliverable(agent_uri)
    end

    test "reports an already-live Agent without replacing its process" do
      agent_uri = Ezagent.URI.new!("entity://team-alpha/agent/already-live-#{u()}")
      put_flavors(%{agent_uri => "py"})
      {:ok, pid} = Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: agent_uri})

      assert {:ok, :live} = Agent.ensure_deliverable(agent_uri)
      assert {:ok, ^pid} = Ezagent.KindRegistry.lookup(agent_uri)
    end
  end

  describe "ensure_declared_member/1" do
    test "starts an absent declared Agent through the owner-gated runtime" do
      agent_uri = Ezagent.URI.new!("entity://team-alpha/agent/declared-member-#{u()}")
      put_flavors(%{agent_uri => "py"})

      assert {:ok, pid} = Agent.ensure_declared_member(agent_uri)
      assert is_pid(pid)
      assert {:ok, ^pid} = Ezagent.KindRegistry.lookup(agent_uri)
    end

    test "reuses the existing process for an already-live declared Agent" do
      agent_uri = Ezagent.URI.new!("entity://team-alpha/agent/declared-live-#{u()}")
      put_flavors(%{agent_uri => "future"})
      {:ok, pid} = Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: agent_uri})

      assert {:ok, ^pid} = Agent.ensure_declared_member(agent_uri)
    end
  end

  describe "materialization command boundary" do
    test "declared materialization preserves atomic adoption metadata" do
      agent_uri = Ezagent.URI.new!("entity://team-alpha/agent/materialized-live-#{u()}")
      put_flavors(%{agent_uri => "future"})
      {:ok, pid} = Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: agent_uri})

      assert {:ok, :already_started, ^pid} = Agent.materialize_declared(agent_uri)
    end

    test "template materialization preserves the owner implementation's invalid-argument result" do
      assert {:error, :invalid_spawn_from_template_content_args} =
               Agent.materialize_from_template(%{}, :invalid, :invalid, :invalid, [])
    end

    test "manifest materialization preserves the owner implementation's invalid-argument result" do
      assert {:error, :invalid_spawn_from_manifest_args} =
               Agent.materialize_from_manifest(:invalid, %{}, :invalid, :invalid, :invalid, [])
    end
  end

  describe "retire_spawned/4" do
    test "refuses retirement when the claimed provenance is absent" do
      agent_uri = Ezagent.URI.new!("entity://team-alpha/agent/foreign-#{u()}")
      owner_uri = Ezagent.URI.new!("entity://team-alpha/user/owner-#{u()}")

      assert {:error, :unverified_spawn_provenance} =
               Agent.retire_spawned(agent_uri, owner_uri, :rollback)
    end

    test "retires an Agent whose durable lineage reaches the claimed root" do
      agent_uri = Ezagent.URI.new!("entity://team-alpha/agent/retire-#{u()}")
      owner_uri = Ezagent.URI.new!("entity://team-alpha/user/owner-#{u()}")
      put_flavors(%{agent_uri => "future"})
      :ok = Ezagent.AgentLineage.record(agent_uri, owner_uri)
      {:ok, _pid} = Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: agent_uri})

      assert {:ok, %{termination: :destroyed, provenance: :verified}} =
               Agent.retire_spawned(agent_uri, owner_uri, :rollback)

      assert :error = Ezagent.KindRegistry.lookup(agent_uri)
    end

    test "records a durable cleanup obligation for the explicit unverified fallback" do
      agent_uri = Ezagent.URI.new!("entity://team-alpha/agent/legacy-#{u()}")

      assert {:partial,
              %{termination: :destroyed, provenance: :unverified, cleanup_obligation: :dlq}} =
               Agent.retire_spawned(agent_uri, nil, :session_delete,
                 allow_unverified_fallback: true
               )

      assert [[payload]] =
               EzagentCore.Repo.query!(
                 "SELECT payload FROM dlq WHERE reason = 'agent_retirement_cleanup' " <>
                   "ORDER BY id DESC LIMIT 1"
               ).rows

      assert Jason.decode!(payload)["target"] == URI.to_string(agent_uri)
    end
  end

  defp put_flavors(flavors) when is_map(flavors) do
    by_uri =
      Map.new(flavors, fn {uri, flavor} ->
        {URI.to_string(uri), flavor}
      end)

    :ets.insert(Ezagent.UriQuery.table(), {:flavor, &resolve_test_flavor(&1, by_uri)})
  end

  defp resolve_test_flavor(%URI{} = uri, by_uri) do
    case Map.fetch(by_uri, URI.to_string(uri)) do
      {:ok, flavor} -> {:ok, flavor}
      :error -> :none
    end
  end

  defp u, do: "#{System.unique_integer([:positive])}"
end
