defmodule Ezagent.PluginEcho.Template.EchoAgentTest do
  @moduledoc """
  Tests for the `echo.agent` Template Class — Domain.Pty SPEC v1
  §10 row 3 + §11 item 6 (deferred PR-D sub-task, now in scope per
  Allen Feishu 2026-05-22).

  Mirrors the structure of `Ezagent.PluginCc.Template.CcAgentTest`:

  - `template_name/0` returns the stable id
  - `validate/1` accepts well-formed templates with/without `with_pty`
  - `validate/1` enforces `cwd` ONLY when `with_pty: true`
  - `instantiate/3` without `with_pty` spawns just the Agent Kind
  - `instantiate/3` with `with_pty: true` ALSO starts a PtyServer
    (verified via `Ezagent.Domain.Pty.alive?/1`)
  - `instantiate/3` is idempotent — re-running on an alive
    Kind + PTY does not duplicate
  - Template Class is registered at boot

  `instantiate/3` touches `Ezagent.SpawnRegistry.spawn/1` which goes
  through the chat domain's `entity://` spawn fn → snapshot
  persistence path → DB writes. This requires sandbox checkout so we
  manually plumb it in `setup` (echo plugin doesn't `use
  EzagentCore.DataCase` because that module lives in another app's
  test/support — and echo's mix.exs deliberately doesn't pull it in).
  """
  use ExUnit.Case, async: false

  alias Ezagent.PluginEcho.Template.EchoAgent

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})
    :ok
  end

  describe "template_name/0" do
    test "returns 'echo.agent'" do
      assert EchoAgent.template_name() == "echo.agent"
    end
  end

  describe "validate/1" do
    test "accepts a well-formed template without with_pty (default)" do
      assert :ok =
               EchoAgent.validate(%{
                 "class" => "echo.agent",
                 "agent_uri" => "entity://agent/default/echo_no-pty"
               })
    end

    test "accepts a well-formed template with `with_pty: false`" do
      assert :ok =
               EchoAgent.validate(%{
                 "class" => "echo.agent",
                 "agent_uri" => "entity://agent/default/echo_off",
                 "with_pty" => false,
                 # cwd allowed but ignored when with_pty: false
                 "cwd" => ""
               })
    end

    test "accepts a well-formed template with `with_pty: true` + cwd" do
      assert :ok =
               EchoAgent.validate(%{
                 "class" => "echo.agent",
                 "agent_uri" => "entity://agent/default/echo_on",
                 "with_pty" => true,
                 "cwd" => "/tmp"
               })
    end

    test "rejects `with_pty: true` without cwd" do
      assert {:error, :cwd_required_when_with_pty} =
               EchoAgent.validate(%{
                 "class" => "echo.agent",
                 "agent_uri" => "entity://agent/default/echo_x",
                 "with_pty" => true
               })
    end

    test "rejects `with_pty: true` with blank cwd" do
      assert {:error, :cwd_required_when_with_pty} =
               EchoAgent.validate(%{
                 "class" => "echo.agent",
                 "agent_uri" => "entity://agent/default/echo_x",
                 "with_pty" => true,
                 "cwd" => ""
               })
    end

    test "rejects missing class" do
      assert {:error, :missing_class_field} =
               EchoAgent.validate(%{"agent_uri" => "entity://agent/default/echo_x"})
    end

    test "rejects wrong class" do
      assert {:error, {:wrong_class, "cc.agent"}} =
               EchoAgent.validate(%{
                 "class" => "cc.agent",
                 "agent_uri" => "entity://agent/default/echo_x"
               })
    end

    test "rejects missing agent_uri" do
      assert {:error, :missing_agent_uri} =
               EchoAgent.validate(%{"class" => "echo.agent"})
    end

    test "rejects wrong agent flavor in name prefix" do
      assert {:error, {:wrong_agent_flavor, "cc", expected: "echo"}} =
               EchoAgent.validate(%{
                 "class" => "echo.agent",
                 "agent_uri" => "entity://agent/default/cc_demo"
               })
    end

    test "rejects entity://agent/<name> without flavor prefix" do
      assert {:error, {:missing_flavor_prefix, _, _}} =
               EchoAgent.validate(%{
                 "class" => "echo.agent",
                 "agent_uri" => "entity://agent/default/just-a-name"
               })
    end

    test "rejects entity://user/... (wrong entity type — must be agent)" do
      assert {:error, {:invalid_agent_uri, _, _}} =
               EchoAgent.validate(%{
                 "class" => "echo.agent",
                 "agent_uri" => "entity://user/default/x"
               })
    end

    test "rejects non-entity scheme" do
      assert {:error, {:bad_agent_uri, _}} =
               EchoAgent.validate(%{
                 "class" => "echo.agent",
                 "agent_uri" => "session://default/default/main"
               })
    end
  end

  describe "instantiate/3 — without with_pty" do
    test "spawns the Agent Kind alone (no PtyServer)" do
      agent_uri_str =
        "entity://agent/default/echo_test-no-pty-#{System.unique_integer([:positive])}"

      agent_uri = URI.parse(agent_uri_str)

      tmpl = %{
        "class" => "echo.agent",
        "agent_uri" => agent_uri_str
      }

      workspace_uri = URI.parse("workspace://test")

      # codex round-6 HIGH-1 — `instantiate/3` returns the 3-element
      # `{:ok, uris, %{fresh?: _}}` form; a first spawn is `fresh?: true`.
      assert {:ok, [^agent_uri], %{fresh?: true}} =
               EchoAgent.instantiate("t", tmpl, workspace_uri)

      # Agent Kind alive
      assert {:ok, agent_pid} = Ezagent.KindRegistry.lookup(agent_uri),
             "Agent Kind must be alive after echo.agent.instantiate without with_pty"

      assert is_pid(agent_pid)
      assert Process.alive?(agent_pid)

      # PtyServer NOT started
      refute Ezagent.Domain.Pty.alive?(agent_uri),
             "PtyServer must NOT be started when with_pty is false/absent"
    end
  end

  describe "instantiate/3 — with with_pty: true" do
    test "spawns BOTH the Agent Kind AND a PtyServer (Domain.Pty SPEC §4 cross-flavor opt-in)" do
      agent_uri_str =
        "entity://agent/default/echo_test-pty-#{System.unique_integer([:positive])}"

      agent_uri = URI.parse(agent_uri_str)

      tmpl = %{
        "class" => "echo.agent",
        "agent_uri" => agent_uri_str,
        "with_pty" => true,
        "cwd" => System.tmp_dir!()
      }

      workspace_uri = URI.parse("workspace://test")

      # codex round-6 HIGH-1 — 3-element return; a first spawn is fresh.
      assert {:ok, [^agent_uri], %{fresh?: true}} =
               EchoAgent.instantiate("t", tmpl, workspace_uri)

      # Both halves alive — the cross-flavor invariant.
      assert {:ok, agent_pid} = Ezagent.KindRegistry.lookup(agent_uri),
             "Agent Kind must be alive after echo.agent.instantiate with_pty: true"

      assert is_pid(agent_pid)
      assert Process.alive?(agent_pid)

      assert Ezagent.Domain.Pty.alive?(agent_uri),
             "PtyServer must be alive after echo.agent.instantiate with_pty: true"

      assert {:ok, pty_pid} = Ezagent.Domain.Pty.lookup(agent_uri)
      assert is_pid(pty_pid)
      assert Process.alive?(pty_pid)
    end

    test "is idempotent — second call returns same URI without spawning a second PtyServer" do
      agent_uri_str =
        "entity://agent/default/echo_idem-#{System.unique_integer([:positive])}"

      agent_uri = URI.parse(agent_uri_str)

      tmpl = %{
        "class" => "echo.agent",
        "agent_uri" => agent_uri_str,
        "with_pty" => true,
        "cwd" => System.tmp_dir!()
      }

      workspace_uri = URI.parse("workspace://test")

      # codex round-6 HIGH-1 — first spawn is fresh, the idempotent
      # re-call adopts the already-live worker (`fresh?: false`).
      assert {:ok, [^agent_uri], %{fresh?: true}} =
               EchoAgent.instantiate("t", tmpl, workspace_uri)

      pids_before = list_pty_pids_for(agent_uri_str)
      assert length(pids_before) == 1

      assert {:ok, [^agent_uri], %{fresh?: false}} =
               EchoAgent.instantiate("t", tmpl, workspace_uri)

      pids_after = list_pty_pids_for(agent_uri_str)
      assert pids_after == pids_before
    end
  end

  describe "registry integration" do
    test "Template Class is registered at boot" do
      assert {:ok, Ezagent.PluginEcho.Template.EchoAgent} =
               Ezagent.TemplateRegistry.lookup("echo.agent")
    end
  end

  describe "form_fields/0" do
    test "declares agent_uri (uri, required), with_pty (boolean), cwd (path)" do
      fields = EchoAgent.form_fields()

      assert Enum.find(fields, fn f -> f.name == "agent_uri" end).type == :uri
      assert Enum.find(fields, fn f -> f.name == "agent_uri" end).required == true

      assert Enum.find(fields, fn f -> f.name == "with_pty" end).type == :boolean
      assert Enum.find(fields, fn f -> f.name == "cwd" end).type == :path
    end
  end

  defp list_pty_pids_for(agent_uri_str) do
    Ezagent.Domain.Pty.Server.list_agents()
    |> Enum.filter(fn a -> URI.to_string(a.agent_uri) == agent_uri_str end)
    |> Enum.map(& &1.pid)
  end
end
