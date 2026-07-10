defmodule Ezagent.PluginCc.Template.CcPtyAfterConfigDirTest do
  @moduledoc """
  Chain B regression (#1096, `72ae93a38`): a cc agent's PTY (`claude`) MUST NOT
  launch before its per-agent `CLAUDE_CONFIG_DIR` has been materialized.

  `#1096` passed `template_class` + `respawn_template_data` as Agent Kind init
  args so `Sandbox.create/1` persists them. That made
  `Sandbox.activate/2`'s `should_ensure_subprocess?/2` true on a FRESH create,
  so `activate` ran the cold-restart self-heal branch — which assumes the config
  dir already exists — and launched `claude` against a directory holding only
  `.claude.json`: no `.credentials.json`, no `.ezagent-config-complete` marker.
  The create path then `stage_and_swap`ed a freshly-copied dir into place via
  `File.rename(target, target.bak)`, yanking the running process's config home
  out from under it. `esr-bridge` never joined → `require_transport_join` never
  resolved → the ReadyGate sat at `:not_ready` forever (the @orchestrator-never-
  replies symptom), and the `identity.grant_cap` `:call` on the create path
  blocked the full 20s activate budget.

  `start_pty/2` swallowed the resulting `{:error, {:already_started, pid}}` into
  `{:ok, pid}`, so the double launch never surfaced.

  This gate is a pure ORDERING assertion and is independent of `Mix.env()`:
  `require_transport_join/1` is skipped in `:test` and `:exec.run/2` is
  short-circuited, but `Domain.Pty.start/2` is still called, and the config-dir
  marker either exists at that moment or it does not.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.PluginCc.Template.CcAgent

  @marker ".ezagent-config-complete"

  defp uniq, do: System.unique_integer([:positive])

  setup do
    agent_uri = URI.new!("entity://team-a/agent/pty-order-#{uniq()}")
    target = CcAgent.agent_config_dir(agent_uri)
    on_exit(fn -> File.rm_rf(target) end)

    ref_dir = Path.join(System.tmp_dir!(), "cc-ref-#{uniq()}")
    File.mkdir_p!(ref_dir)
    File.write!(Path.join(ref_dir, ".credentials.json"), "TOKEN")
    File.write!(Path.join(ref_dir, "settings.json"), "SETTINGS")
    on_exit(fn -> File.rm_rf(ref_dir) end)

    cwd = Path.join(System.tmp_dir!(), "cc-cwd-#{uniq()}")
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf(cwd) end)

    tmpl = %{
      "class" => "cc.agent",
      "agent_uri" => URI.to_string(agent_uri),
      "cwd" => cwd,
      "config_dir" => ref_dir,
      # In production this key is injected by
      # `Ezagent.Kind.Template.provision_and_instantiate/4`.
      "allocated_config_dir" => target
    }

    {:ok, agent_uri: agent_uri, target: target, tmpl: tmpl}
  end

  test "Pty.start never fires before the per-agent config dir is materialized", ctx do
    marker = Path.join(ctx.target, @marker)
    creds = Path.join(ctx.target, ".credentials.json")
    me = self()

    {:ok, _} =
      :dbg.tracer(
        :process,
        {fn msg, acc ->
           send(me, {:pty_start, File.exists?(marker), File.exists?(creds), msg})
           acc
         end, nil}
      )

    {:ok, _} = :dbg.p(:all, [:call])
    :dbg.tpl(Ezagent.Domain.Pty, :start, 2, [])

    try do
      assert {:ok, [_uri], _meta} =
               CcAgent.instantiate("cc.agent", ctx.tmpl, URI.new!("workspace://team-a"))

      # `activate/2` runs in the Agent Kind's `handle_continue`; give it — and any
      # supervised provisioning task — room to reach `Pty.start`.
      assert wait_for_pty_start(2_000), "Domain.Pty.start/2 was never called"
    after
      :dbg.stop()
    end

    for {marker?, creds?} <- collect_pty_starts() do
      assert marker?,
             "Pty.start fired while #{@marker} was ABSENT — claude launched against " <>
               "an unmaterialized CLAUDE_CONFIG_DIR (chain B, #1096)"

      assert creds?,
             "Pty.start fired while .credentials.json was ABSENT — claude launched " <>
               "without credentials, so esr-bridge can never join"
    end
  end

  defp wait_for_pty_start(0), do: false

  defp wait_for_pty_start(budget_ms) do
    receive do
      {:pty_start, _, _, _} = evt ->
        send(self(), evt)
        true
    after
      50 -> wait_for_pty_start(max(budget_ms - 50, 0))
    end
  end

  defp collect_pty_starts(acc \\ []) do
    receive do
      {:pty_start, marker?, creds?, {:trace, _pid, :call, {_m, :start, _a}}} ->
        collect_pty_starts([{marker?, creds?} | acc])

      {:pty_start, _, _, _} ->
        collect_pty_starts(acc)
    after
      50 ->
        assert acc != [], "no Domain.Pty.start/2 trace captured"
        acc
    end
  end
end
