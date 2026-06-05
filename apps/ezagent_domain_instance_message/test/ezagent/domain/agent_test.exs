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
  - Unregistered URI → `:not_found` with flavor still derived
    from the URI name prefix (so UI can render "echo agent does
    not exist" vs just "agent does not exist")
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Domain.Agent, SpawnRegistry}

  describe "lifecycle_status/1 — flavor derivation" do
    test "derives flavor from agent name prefix (cc_*, echo_*, curl_*)" do
      # The URI doesn't need to be registered; derive_flavor just
      # parses the name. :not_found still carries the derived flavor.
      cc_uri = URI.parse("entity://agent/team-alpha/cc_unregistered-#{u()}")
      echo_uri = URI.parse("entity://agent/team-alpha/echo_unregistered-#{u()}")
      curl_uri = URI.parse("entity://agent/team-alpha/curl_unregistered-#{u()}")

      assert %{phase: :not_found, flavor: "cc", detail: nil} =
               Agent.lifecycle_status(cc_uri)

      assert %{phase: :not_found, flavor: "echo", detail: nil} =
               Agent.lifecycle_status(echo_uri)

      assert %{phase: :not_found, flavor: "curl", detail: nil} =
               Agent.lifecycle_status(curl_uri)
    end

    test "returns nil flavor for unrecognized URI shape" do
      not_an_agent = URI.parse("entity://user/team-alpha/admin")
      workspace = URI.parse("workspace://team-alpha")

      assert %{phase: :not_found, flavor: nil, detail: nil} =
               Agent.lifecycle_status(not_an_agent)

      assert %{phase: :not_found, flavor: nil, detail: nil} =
               Agent.lifecycle_status(workspace)
    end
  end

  describe "lifecycle_status/1 — echo flavor (alive Kind, no PTY layer)" do
    test "alive echo Kind returns %{phase: :alive, flavor: \"echo\", detail: %{}}" do
      echo_uri = URI.parse("entity://agent/team-alpha/echo_lifecycle-#{u()}")

      # Spawn the echo Kind via the standardized SpawnRegistry path
      # (chat's entity:// spawn fn → spawn_agent/1 → flavor-prefix
      # resolver lands echo Kinds in EzagentDomainInstanceMessage.AgentSupervisor).
      {:ok, pid} = SpawnRegistry.spawn(echo_uri)
      assert is_pid(pid) and Process.alive?(pid)

      assert %{phase: :alive, flavor: "echo", detail: %{}} =
               Agent.lifecycle_status(echo_uri)
    end
  end

  describe "lifecycle_status/1 — PTY detection is flavor-agnostic" do
    test "alive cc Kind without PtyServer returns :alive with empty detail" do
      cc_uri = URI.parse("entity://agent/team-alpha/cc_lifecycle-#{u()}")
      {:ok, pid} = SpawnRegistry.spawn(cc_uri)
      assert is_pid(pid) and Process.alive?(pid)

      assert %{phase: :alive, flavor: "cc", detail: %{}} =
               Agent.lifecycle_status(cc_uri)
    end

    test "alive curl and future-flavor Kinds without PtyServer return :alive with empty detail" do
      curl_uri = URI.parse("entity://agent/team-alpha/curl_lifecycle-#{u()}")
      future_uri = URI.parse("entity://agent/team-alpha/future_lifecycle-#{u()}")

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
      codex_uri = URI.parse("entity://agent/team-alpha/codex_lifecycle-#{u()}")

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
    test "non-existent agent URI returns :not_found with derived flavor" do
      cc_uri = URI.parse("entity://agent/team-alpha/cc_does-not-exist-#{u()}")

      assert %{phase: :not_found, flavor: "cc", detail: nil} =
               Agent.lifecycle_status(cc_uri)
    end
  end

  defp u, do: "#{System.unique_integer([:positive])}"
end
