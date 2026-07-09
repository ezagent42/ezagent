defmodule Ezagent.PluginCc.Template.CcAgentSpawnInvariantTest do
  @moduledoc """
  Spawn-path invariant guard added 2026-05-26 alongside the
  mention-parser regression fix. Allen 09:27 report: "cc 的 spawn
  function 消失了". Investigation showed spawn is still working —
  PtyServer DOES launch the `claude` CLI on cc-agent creation.
  The actual perceived regression was a separate mention-parser /
  mention-gated-dispatch interaction (see
  `admin_live_mention_parse_test.exs`).

  Even though the spawn path isn't broken NOW, Allen explicitly asked
  for a test that catches FUTURE regressions of the spawn flow. The
  pre-2026-05-26 invariant coverage was:

  * `cc_agent_test.exs` — exercises `instantiate/3` but uses
    `Mix.env() == :test` short-circuit (test_mode=true) so the
    `cmd_override` argv is NEVER built. A bug that breaks
    `build_pty_params/3` in non-test envs would slip past this.

  * `cc_agent_argv_path_test.exs` — exercises
    `resolve_claude_executable/1` and real list-form `:exec.run/2`
    launches but does NOT cover the assembly path
    (`build_claude_cmd/3` → `build_pty_params/3` →
    `Ezagent.Domain.Pty.start/2` params shape).

  * `cc_agent_sandbox_credentials_test.exs` — REBUILDS the production
    argv outside the plugin (line 521 docstring acknowledges:
    "if `CcAgent.build_claude_cmd/3` is ever exposed (`@doc false`),
    both tests should switch to it"). A divergence between the
    rebuild and the production builder would pass the test while
    production breaks (the exact "test passes, prod regressed" trap
    Allen wants to prevent).

  This test fills that gap:

  1. `build_claude_cmd/3` returns an argv list whose element 0 is the
     resolved absolute `claude` path (not bare `"claude"`).
  2. The argv contains `--permission-mode bypassPermissions` +
     `--dangerously-load-development-channels server:esr-bridge`.
  3. The trusted `--mcp-config <bridge.mcp.json>` is present
     (the Python MCP bridge is what JOINs `cc:bridge:<uri>` — without
     this flag, claude never opens the bridge and chat dispatches
     have nowhere to go).
  4. The mandatory plugin `--settings <claude-pty-settings.json>` is
     present and is LAST (claude's `--settings` is last-wins, so
     `remoteControlAtStartup: false` must be after any operator
     override).
  5. `cmd_env` carries `EZAGENT_AGENT_URI` + `EZAGENT_AGENT_TOKEN`
     (the Python bridge reads these to authenticate the WS join).
  6. `build_pty_params/3` in non-test env carries `:cmd_override`
     into the params Map handed to `Ezagent.Domain.Pty.start/2` —
     a future refactor that DROPS `:cmd_override` would silently
     leave the PTY without a child program → no claude → no bridge
     join → no reply.

  These are STRUCTURAL invariants of the boot path, not
  test-data invariants — they trip the moment the production code
  paths diverge from "build the claude argv and hand it to the
  Domain.Pty Server".
  """

  use ExUnit.Case, async: false

  alias Ezagent.PluginCc.Template.CcAgent
  alias Ezagent.PluginCc.Template.SpawnPlan

  @agent_uri Ezagent.URI.new!("entity://system/agent/cc_spawn-invariant-test")
  @cwd System.tmp_dir!()

  setup do
    original_path = System.get_env("PATH")

    on_exit(fn ->
      if original_path do
        System.put_env("PATH", original_path)
      else
        System.delete_env("PATH")
      end
    end)

    bin_dir =
      Path.join(
        System.tmp_dir!(),
        "cc_spawn_invariant_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(bin_dir)
    on_exit(fn -> File.rm_rf(bin_dir) end)

    mock_path = Path.join(bin_dir, "claude")

    File.write!(mock_path, """
    #!/usr/bin/env bash
    if [ "$1" = "--help" ]; then
      echo "Usage: claude [options]"
      echo "  --dangerously-skip-permissions"
      exit 0
    fi
    if [ "$1" = "--dangerously-load-development-channels" ]; then
      shift 2
      if [ "$1" = "--help" ]; then
        echo "Usage: claude [options]"
        exit 0
      fi
      exit 0
    fi
    exit 0
    """)

    File.chmod!(mock_path, 0o755)

    # Prepend so PATH-search finds OUR mock first (the real `claude`
    # may also be on PATH on the dev box).
    System.put_env("PATH", bin_dir <> ":" <> (original_path || ""))

    {:ok, mock_claude_path: mock_path, bin_dir: bin_dir, original_path: original_path || ""}
  end

  describe "build_claude_cmd/3 — production argv invariants" do
    test "argv element 0 is the resolved absolute `claude` path", %{
      mock_claude_path: mock_path
    } do
      tmpl = base_tmpl()

      assert {:ok, {argv, _env}} = CcAgent.build_claude_cmd(@agent_uri, @cwd, tmpl)
      assert is_list(argv)

      [cmd | _rest] = argv

      assert is_binary(cmd)

      assert Path.type(cmd) == :absolute,
             "argv[0] must be an absolute path (erlexec list-form :exec.run runs " <>
               "execve(3) with no PATH search) — got #{inspect(cmd)}"

      assert cmd == mock_path,
             "argv[0] must be the PATH-resolved `claude` (the test installed a " <>
               "mock at #{mock_path}) — got #{inspect(cmd)}"
    end

    test "accepts dev-channel support even when --help omits the flag", %{
      mock_claude_path: mock_path
    } do
      assert SpawnPlan.claude_dev_channels_supported?(mock_path)
      assert :ok = SpawnPlan.ensure_dev_channels_supported(mock_path)
      assert {:ok, {_argv, _env}} = CcAgent.build_claude_cmd(@agent_uri, @cwd, base_tmpl())
    end

    test "argv carries the bypass + dev-channels flags" do
      tmpl = base_tmpl()

      assert {:ok, {argv, _env}} = CcAgent.build_claude_cmd(@agent_uri, @cwd, tmpl)

      # 2026-06-01 headless-reply fix: bypass mode is enabled via
      # `--dangerously-skip-permissions`, NOT `--permission-mode
      # bypassPermissions`. The latter triggers an interactive "Yes, I
      # accept" startup confirmation a headless PTY can't answer →
      # claude parks pre-REPL, never loads the esr-bridge channel, and
      # silently drops inbound messages (agent never replies). The skip
      # flag runs the same bypass mode with no dialog.
      assert "--dangerously-skip-permissions" in argv

      refute "bypassPermissions" in argv,
             "--permission-mode bypassPermissions reintroduces the startup " <>
               "confirmation dialog that mutes headless cc agents"

      assert "--dangerously-load-development-channels" in argv
      assert "server:esr-bridge" in argv

      # Flag + value must be adjacent — a regression that inserted
      # something between them would break the dev-channels enable.
      # (The dev-channels confirmation itself is auto-answered by the
      # PtyServer auto-prompt scanner, reachable only now that the
      # bypass dialog above is gone.)
      assert adjacent?(
               argv,
               "--dangerously-load-development-channels",
               "server:esr-bridge"
             )
    end

    test "argv `--mcp-config` is the PER-AGENT cwd path, NOT the shared global (Allen 2026-05-26 e2e Bug 4)" do
      # Pre-fix, --mcp-config pointed at ~/.ezagent/bridge.mcp.json
      # (shared/global). With two cc agents alive, the second spawn
      # OVERWROTE that file with its own URI+token. Agent N's claude
      # TUI then read the file at MCP-server-start time, saw agent M's
      # URI, and authenticated the WS bridge as M. Symptom: only the
      # last-spawned agent ever has an active `cc:bridge:<URI>`
      # channel; every other agent's inbound chat.receive is audited
      # as :no_bridge → silent drop. Pin the per-agent cwd path here
      # so this never regresses.
      tmpl = base_tmpl()

      assert {:ok, {argv, _env}} = CcAgent.build_claude_cmd(@agent_uri, @cwd, tmpl)

      idx = Enum.find_index(argv, &(&1 == "--mcp-config"))
      mcp_path = Enum.at(argv, idx + 1)
      expected = Path.join(@cwd, ".mcp.json")

      assert mcp_path == expected,
             """
             --mcp-config must point at the per-agent cwd's .mcp.json
             (`<agent_cwd>/.mcp.json`), NOT the shared global. The shared
             global file gets LATEST-WRITER-WINS-overwritten by every
             other cc agent's spawn — agent N's claude TUI then reads
             the file at MCP-server-start and authenticates the WS
             bridge as the LATEST-SPAWNED agent (likely not N).

             Expected: #{expected}
             Got:      #{mcp_path}
             """
    end

    test "argv carries the trusted bridge --mcp-config (the WS-bridge enable)" do
      # Without `--mcp-config <bridge.mcp.json>`, the Python MCP bridge
      # NEVER starts, so the JOIN to `cc:bridge:<uri>` never happens
      # and the chat fan-out has no recipient channel — even with a
      # healthy PtyServer running claude. This is the most load-bearing
      # flag in the entire spawn path.
      tmpl = base_tmpl()

      assert {:ok, {argv, _env}} = CcAgent.build_claude_cmd(@agent_uri, @cwd, tmpl)

      assert "--mcp-config" in argv,
             "argv must include --mcp-config (Python MCP bridge enable) — got: #{inspect(argv)}"

      # The path follows the flag (argv-pair shape).
      idx = Enum.find_index(argv, &(&1 == "--mcp-config"))
      mcp_path = Enum.at(argv, idx + 1)

      assert is_binary(mcp_path),
             "--mcp-config must be immediately followed by a path — argv: #{inspect(argv)}"

      assert File.exists?(mcp_path),
             "the --mcp-config path must exist after the assembler runs — got #{inspect(mcp_path)}"
    end

    test "the mandatory plugin --settings is LAST (last-wins safety invariant)" do
      tmpl = base_tmpl()

      assert {:ok, {argv, _env}} = CcAgent.build_claude_cmd(@agent_uri, @cwd, tmpl)

      # claude's `--settings` is last-wins. Plugin safety
      # (`remoteControlAtStartup: false`) MUST be after any operator
      # override. We don't carry an operator override in this test, but
      # the mandatory plugin path is still expected to appear AS A
      # `--settings <path>` pair somewhere in argv.
      assert "--settings" in argv

      idx = Enum.find_index(argv, &(&1 == "--settings"))
      settings_path = Enum.at(argv, idx + 1)

      assert is_binary(settings_path)
      assert String.ends_with?(settings_path, "claude-pty-settings.json")

      # Sanity: this is the ONLY --settings in the base case (no
      # operator override). When an operator override is added, the
      # plugin --settings must remain AFTER it; we cover that case in
      # `assemble_settings_mcp_args/3`'s dedicated test
      # (cc_agent_extensions_test.exs / sandbox-credentials).
      assert Enum.count(argv, &(&1 == "--settings")) == 1
    end

    test "cmd_env carries the per-agent EZAGENT_AGENT_URI + token (bridge auth)" do
      tmpl = base_tmpl()

      assert {:ok, {_argv, env}} = CcAgent.build_claude_cmd(@agent_uri, @cwd, tmpl)

      assert env["EZAGENT_AGENT_URI"] == URI.to_string(@agent_uri)

      assert is_binary(env["EZAGENT_AGENT_TOKEN"]) and env["EZAGENT_AGENT_TOKEN"] != "",
             "EZAGENT_AGENT_TOKEN must be a non-empty binary — the Python bridge " <>
               "rejects a join without a valid token. Got: #{inspect(env["EZAGENT_AGENT_TOKEN"])}"
    end

    test "{:error, :claude_not_found} when claude is not on PATH (no shell fallback)", %{
      bin_dir: bin_dir
    } do
      # PATH that contains an empty dir → `System.find_executable/1` returns nil.
      empty_dir = Path.join(bin_dir, "empty")
      File.mkdir_p!(empty_dir)
      System.put_env("PATH", empty_dir)

      assert {:error, :claude_not_found} =
               CcAgent.build_claude_cmd(@agent_uri, @cwd, base_tmpl())
    end

    test "returns a clear error when the installed claude lacks dev-channel support", %{
      bin_dir: bin_dir,
      original_path: original_path
    } do
      unsupported_dir = Path.join(bin_dir, "unsupported")
      File.mkdir_p!(unsupported_dir)
      unsupported_path = Path.join(unsupported_dir, "claude")

      File.write!(unsupported_path, """
      #!/usr/bin/env bash
      if [ "$1" = "--dangerously-load-development-channels" ]; then
        echo "error: unknown option --dangerously-load-development-channels"
        exit 1
      fi
      if [ "$1" = "--help" ]; then
        echo "Usage: claude [options]"
        echo "  --dangerously-skip-permissions"
        echo "  --mcp-config <file>"
        exit 0
      fi
      exit 0
      """)

      File.chmod!(unsupported_path, 0o755)
      System.put_env("PATH", unsupported_dir <> ":" <> original_path)

      assert {:error, {:unsupported_claude_dev_channels, ^unsupported_path}} =
               CcAgent.build_claude_cmd(@agent_uri, @cwd, base_tmpl())
    end
  end

  describe "build_pty_params_for_env/4 — Domain.Pty Server boundary invariants" do
    test ":dev env params carry :cmd_override + :cmd_env (production shape)" do
      # Codex 2026-05-26 MEDIUM — exercise the NON-TEST branch directly
      # via the env-injected helper. The Domain.Pty.start/2 contract
      # requires the exact `:cmd_override` key — see
      # `Ezagent.Domain.Pty.start/2` docstring. A future refactor
      # that renames it (e.g. to `:argv`) would silently leave
      # `cmd_override = nil` in the Server, raising
      # `build_exec_cmd(nil, _)` at runtime → no claude → no bridge.
      # The Server's `init/1` reads `Map.get(args, :cmd_override)`;
      # this test pins the key against the REAL production code path.
      tmpl = base_tmpl()

      assert {:ok, params} = CcAgent.build_pty_params_for_env(@agent_uri, @cwd, tmpl, :dev)

      assert Map.has_key?(params, :cmd_override),
             "Domain.Pty.start/2 contract requires :cmd_override — got keys: #{inspect(Map.keys(params))}"

      assert Map.has_key?(params, :cmd_env)
      assert Map.has_key?(params, :cwd)
      refute Map.has_key?(params, :test_mode), ":dev branch must NOT return test_mode: true"

      assert is_list(params.cmd_override),
             "Domain.Pty.Server expects cmd_override as an argv LIST (not a shell string) — " <>
               "the cc plugin must always use list form (codex HIGH-2)"

      [cmd | _] = params.cmd_override
      assert Path.type(cmd) == :absolute
    end

    test ":prod env params carry :cmd_override (same shape as :dev)" do
      tmpl = base_tmpl()

      assert {:ok, params} = CcAgent.build_pty_params_for_env(@agent_uri, @cwd, tmpl, :prod)

      assert Map.has_key?(params, :cmd_override)
      assert is_list(params.cmd_override)
      refute Map.has_key?(params, :test_mode)
    end

    test ":test env returns test_mode params (regression guard for prod leakage)" do
      # build_pty_params/3 is the ONE branch point that decides
      # "test_mode short-circuit vs. real claude argv". A bug that
      # accidentally returned `test_mode: true` in `:dev` / `:prod`
      # would mean PtyServer NEVER spawns claude, exactly the symptom
      # Allen worried about. Pin both directions: :test short-circuits;
      # :dev / :prod must NOT (above).
      tmpl = base_tmpl()

      assert {:ok, %{test_mode: true, cwd: @cwd}} =
               CcAgent.build_pty_params_for_env(@agent_uri, @cwd, tmpl, :test)
    end

    test "build_pty_params/3 delegates to build_pty_params_for_env/4 with Mix.env()" do
      # Sanity that the 3-arg public alias matches the 4-arg form for
      # the current env. Under :test that means both return test_mode
      # params; under :dev / :prod they'd return the cmd_override shape.
      tmpl = base_tmpl()

      assert CcAgent.build_pty_params(@agent_uri, @cwd, tmpl) ==
               CcAgent.build_pty_params_for_env(@agent_uri, @cwd, tmpl, Mix.env())
    end
  end

  describe "build_claude_cmd/3 — last-wins --settings invariant with operator override" do
    test "mandatory plugin --settings is the LAST --settings VALUE (not just last argv)", %{
      mock_claude_path: _mock_path
    } do
      # Codex 2026-05-26 LOW — the base test only checks "exactly one
      # --settings" in argv. The real invariant is "the LAST --settings
      # value is the mandatory plugin path" (claude's --settings is
      # last-wins; an operator override appears EARLIER in argv, the
      # plugin's safety override appears LATER, so the safety wins).
      # With operator_settings_path set we should see TWO --settings
      # flags; assert the LAST value is the mandatory plugin path.
      operator_settings =
        Path.join(
          System.tmp_dir!(),
          "operator-settings-#{System.unique_integer([:positive])}.json"
        )

      File.write!(operator_settings, "{}\n")
      on_exit(fn -> File.rm(operator_settings) end)

      tmpl =
        base_tmpl()
        |> Map.put("operator_settings_path", operator_settings)

      assert {:ok, {argv, _env}} = CcAgent.build_claude_cmd(@agent_uri, @cwd, tmpl)

      # Two --settings flags in this case.
      assert Enum.count(argv, &(&1 == "--settings")) == 2

      # Collect values immediately following each --settings flag,
      # then take the LAST. That MUST be the mandatory plugin path
      # (claude-pty-settings.json under :code.priv_dir(:ezagent_plugin_cc)).
      values = settings_values(argv)
      assert length(values) == 2

      last_value = List.last(values)

      assert String.ends_with?(last_value, "claude-pty-settings.json"),
             "the LAST --settings value must be the mandatory plugin path (last-wins safety) — " <>
               "got #{inspect(values)}"

      # The operator value appears first (gets overridden).
      assert List.first(values) == operator_settings
    end
  end

  # ---------------------------------------------------------------------------

  defp base_tmpl do
    %{
      "class" => "cc.agent",
      "agent_uri" => URI.to_string(@agent_uri),
      "cwd" => @cwd
    }
  end

  defp adjacent?(list, a, b) do
    case Enum.find_index(list, &(&1 == a)) do
      nil -> false
      i -> Enum.at(list, i + 1) == b
    end
  end

  # Collect every value that follows a `--settings` flag in argv.
  # Used by the last-wins invariant test.
  defp settings_values(argv) do
    argv
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {"--settings", i} -> [Enum.at(argv, i + 1)]
      _ -> []
    end)
  end
end
