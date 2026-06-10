defmodule Ezagent.Sandbox.ConfigDirParityTest do
  @moduledoc """
  Resource-unification P1 — `Ezagent.Sandbox.ConfigDir.path/2` now resolves the
  per-agent config-dir through the hardened `Ezagent.Resource.FsResolver`
  (`resource://<ws>/<ns>-agents/<name>`) instead of building a raw
  `Home.path("<ns>-agents")/<ws>/<name>` directly.

  The locked contract (SPEC §3, Locked-contract #7) is **byte-identical** output:
  every `(workspace, name, namespace)` triple resolves to the exact same string it
  did pre-P1. These tests pin that invariant and the codex-CRITICAL authority
  guard (a forged cross-`<ws>` resource URI must fail loud, never self-scope).
  """
  use ExUnit.Case, async: false

  alias Ezagent.Home
  alias Ezagent.Sandbox.ConfigDir
  alias Ezagent.URI, as: EzURI

  defp agent_uri(ws, name), do: EzURI.new!("entity://#{ws}/agent/#{name}")

  describe "byte-identical parity (Locked-contract #7)" do
    test "P1: config_dir path is BYTE-IDENTICAL to the pre-P1 raw Home layout (cc)" do
      uri = agent_uri("acme", "worker-1")
      # The pre-P1 layout (SPEC §3 / config_dir.ex docstring):
      expected = Path.join([Home.path("cc-agents"), "acme", "worker-1"])
      assert ConfigDir.path(uri, "cc") == expected
    end

    test "P1: byte-identical for the codex namespace too" do
      uri = agent_uri("tenant-b", "agent_x")
      expected = Path.join([Home.path("codex-agents"), "tenant-b", "agent_x"])
      assert ConfigDir.path(uri, "codex") == expected
    end

    test "P1: parity holds across a spread of (ws, name) samples" do
      for {ns, ws, name} <- [
            {"cc", "w1", "a"},
            {"cc", "workspace-with-dashes", "agent_with_underscores"},
            {"codex", "w2", "b"},
            {"cc", "UpperWs", "MixedCaseName"}
          ] do
        uri = agent_uri(ws, name)
        expected = Path.join([Home.path("#{ns}-agents"), ws, name])

        assert ConfigDir.path(uri, ns) == expected,
               "parity drift for #{ns}/#{ws}/#{name}"
      end
    end
  end

  describe "authority (codex CRITICAL — non-tautological)" do
    test "P1: foreign-<ws> authority fails loud at the resolver" do
      # Building resource://victim/cc-agents/x and resolving under scope acme must
      # fail — the resolver's authority/2 is the FS auth boundary.
      uri = EzURI.resource("victim", "cc-agents", "worker-1")
      assert {:error, _} = Ezagent.Resource.FsResolver.resolve(uri, %{workspace: "acme"})
    end

    test "P1: same-<ws> authority succeeds and is byte-identical" do
      uri = EzURI.resource("acme", "cc-agents", "worker-1")

      assert {:ok, path} = Ezagent.Resource.FsResolver.resolve(uri, %{workspace: "acme"})
      assert path == Path.join([Home.path("cc-agents"), "acme", "worker-1"])
    end
  end
end
