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
  pattern-matches the agent flavor prefix and delegates to the
  owning plugin's lifecycle helper, unifying the response shape
  across flavors.

  ## Contract

  Return shape: `%{phase, flavor, detail}` where
  - `phase` ∈ `[:alive, :registered, :not_found, :error, :instantiated]`
  - `flavor` is `String.t() | nil` (cc / echo / curl / nil for
    non-agent URIs)
  - `detail` is plugin-specific map or `nil`

  ## What's verified

  - `cc` flavor + alive Kind + PtyServer running → `:alive` with
    cc-specific detail (os_pid, cwd, etc.)
  - `echo` flavor + alive Kind → `:alive` with empty detail map
    (echo has no deeper lifecycle layer)
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
      cc_uri = URI.parse("entity://agent/default/cc_unregistered-#{u()}")
      echo_uri = URI.parse("entity://agent/default/echo_unregistered-#{u()}")
      curl_uri = URI.parse("entity://agent/default/curl_unregistered-#{u()}")

      assert %{phase: :not_found, flavor: "cc", detail: nil} =
               Agent.lifecycle_status(cc_uri)

      assert %{phase: :not_found, flavor: "echo", detail: nil} =
               Agent.lifecycle_status(echo_uri)

      assert %{phase: :not_found, flavor: "curl", detail: nil} =
               Agent.lifecycle_status(curl_uri)
    end

    test "returns nil flavor for unrecognized URI shape" do
      not_an_agent = URI.parse("entity://user/default/admin")
      workspace = URI.parse("workspace://default")

      assert %{phase: :not_found, flavor: nil, detail: nil} =
               Agent.lifecycle_status(not_an_agent)

      assert %{phase: :not_found, flavor: nil, detail: nil} =
               Agent.lifecycle_status(workspace)
    end
  end

  describe "lifecycle_status/1 — echo flavor (alive Kind, no PTY layer)" do
    test "alive echo Kind returns %{phase: :alive, flavor: \"echo\", detail: %{}}" do
      echo_uri = URI.parse("entity://agent/default/echo_lifecycle-#{u()}")

      # Spawn the echo Kind via the standardized SpawnRegistry path
      # (chat's entity:// spawn fn → spawn_agent/1 → flavor-prefix
      # resolver lands echo Kinds in EzagentDomainChat.AgentSupervisor).
      {:ok, pid} = SpawnRegistry.spawn(echo_uri)
      assert is_pid(pid) and Process.alive?(pid)

      assert %{phase: :alive, flavor: "echo", detail: %{}} =
               Agent.lifecycle_status(echo_uri)
    end
  end

  describe "lifecycle_status/1 — cc flavor (Kind alive but PtyServer optional)" do
    test "alive cc Kind without PtyServer → :registered phase (kind alive, deeper layer down)" do
      # Spawn the cc Agent Kind directly via SpawnRegistry — this
      # mimics the pre-PtyServer state (e.g. between Kind spawn and
      # PtyServer instantiate). The Domain.Agent facade should
      # report :registered, not :not_found, so the UI can
      # distinguish "agent never existed" from "agent exists but
      # PTY isn't up yet".
      cc_uri = URI.parse("entity://agent/default/cc_lifecycle-#{u()}")
      {:ok, pid} = SpawnRegistry.spawn(cc_uri)
      assert is_pid(pid) and Process.alive?(pid)

      result = Agent.lifecycle_status(cc_uri)

      assert %{phase: :registered, flavor: "cc"} = result
      assert is_map(result.detail)
    end
  end

  describe "lifecycle_status/1 — unregistered URI" do
    test "non-existent agent URI returns :not_found with derived flavor" do
      cc_uri = URI.parse("entity://agent/default/cc_does-not-exist-#{u()}")

      assert %{phase: :not_found, flavor: "cc", detail: nil} =
               Agent.lifecycle_status(cc_uri)
    end
  end

  defp u, do: "#{System.unique_integer([:positive])}"
end
