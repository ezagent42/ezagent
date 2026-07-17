defmodule Ezagent.PluginCc.Template.CcAgentTest do
  @moduledoc """
  Unified `cc.agent` Template Class. The `mode` field was removed
  Allen 2026-05-21 (V1 fix) — local-pty is the only path. Tests for
  remote-channel placeholder + mode-validation were deleted with it.

  Allen 2026-05-21 V1 fix: instantiate now spawns BOTH the Agent
  Kind (via `SpawnRegistry.spawn/1` → snapshot persistence path) AND
  the PtyServer. The Agent Kind path needs DB sandbox checkout, so
  this suite uses `EzagentCore.DataCase` rather than a plain
  `ExUnit.Case`.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.PluginCc.Template.CcAgent

  describe "launch-context callback matrix" do
    test "all cc variants expose instantiate/4 while retaining instantiate/3" do
      modules = [
        CcAgent,
        Ezagent.PluginCc.Template.CcHeadlessAgent,
        Ezagent.PluginCc.Template.CcDeepseekAgent,
        Ezagent.PluginCc.Template.CcHeadlessDeepseekAgent
      ]

      for module <- modules do
        assert function_exported?(module, :instantiate, 3)
        assert function_exported?(module, :instantiate, 4)

        assert {:error, :invalid_launch_options} =
                 module.instantiate("test", %{}, URI.new!("workspace://test"),
                   launch_context_typo: make_ref()
                 )
      end
    end
  end

  describe "template_name/0" do
    test "returns 'cc.agent'" do
      assert CcAgent.template_name() == "cc.agent"
    end
  end

  describe "compile/2" do
    test "purely compiles resolved manifest instructions into cc template data" do
      resolved = %{
        instructions: "You are the CINNOX support agent.",
        skills: ["kb_search"]
      }

      params = %{
        "claude_md_preamble" => "runtime note\n\n",
        "mcp_config_path" => "/tmp/mcp.json",
        "settings_path" => "/tmp/settings.json"
      }

      assert {:ok, data} = CcAgent.compile(resolved, params)

      assert data["claude_md"] == "runtime note\n\nYou are the CINNOX support agent."
      assert data["operator_mcp_config_path"] == "/tmp/mcp.json"
      assert data["operator_settings_path"] == "/tmp/settings.json"
      refute Map.has_key?(data, "derived_config")
    end

    test "emits manifest MCP entries with empty ctx_caps" do
      resolved = %{
        instructions: "Use tools only through dispatch.",
        skills: [],
        tools: [
          %{
            name: "notify_owner",
            type: :action,
            action: "entity://system/user/admin?action=notifications.notify",
            caps: [%{"kind" => "user"}],
            optional: false
          }
        ]
      }

      assert {:ok, data} = CcAgent.compile(resolved, %{})

      assert data["manifest_tools"] == resolved.tools
      assert data["manifest_mcp_servers"]["notify_owner"]["ctx_caps"] == []
      assert data["manifest_mcp_servers"]["notify_owner"]["tool_type"] == "action"
    end
  end

  describe "validate/1" do
    test "accepts a well-formed template" do
      assert :ok =
               CcAgent.validate(%{
                 "class" => "cc.agent",
                 "agent_uri" => "entity://team-alpha/agent/cc_cc-architect",
                 "cwd" => "/tmp"
               })
    end

    test "tolerates legacy `mode` field (silently ignored, no migration needed)" do
      # PR-D2 migration seeded `mode: "local-pty"` into existing rows.
      # The V1 fix removed the field from the schema but did NOT
      # migrate the JSON — legacy rows must still validate, since
      # extra fields are non-load-bearing per the let-it-crash
      # principle (no shims, just structural irrelevance).
      assert :ok =
               CcAgent.validate(%{
                 "class" => "cc.agent",
                 "agent_uri" => "entity://team-alpha/agent/cc_legacy",
                 "mode" => "local-pty",
                 "cwd" => "/tmp"
               })
    end

    test "rejects missing class" do
      assert {:error, :missing_class_field} =
               CcAgent.validate(%{
                 "agent_uri" => "entity://team-alpha/agent/cc_x",
                 "cwd" => "/tmp"
               })
    end

    test "rejects wrong class" do
      assert {:error, {:wrong_class, "cc.pty"}} =
               CcAgent.validate(%{
                 "class" => "cc.pty",
                 "agent_uri" => "entity://team-alpha/agent/cc_x",
                 "cwd" => "/tmp"
               })
    end

    test "rejects missing agent_uri" do
      assert {:error, :missing_agent_uri} =
               CcAgent.validate(%{"class" => "cc.agent", "cwd" => "/tmp"})
    end

    test "rejects entity://team-alpha/user/X (wrong entity type — must be agent)" do
      assert {:error, {:invalid_agent_uri, _, _}} =
               CcAgent.validate(%{
                 "class" => "cc.agent",
                 "agent_uri" => "entity://team-alpha/user/x",
                 "cwd" => "/tmp"
               })
    end

    test "rejects non-entity scheme entirely" do
      assert {:error, {:invalid_agent_uri, _, "agent URI must be an entity agent URI"}} =
               CcAgent.validate(%{
                 "class" => "cc.agent",
                 "agent_uri" => "session://system/default/main",
                 "cwd" => "/tmp"
               })
    end

    test "accepts entity://agent/<name> without flavor prefix" do
      assert :ok =
               CcAgent.validate(%{
                 "class" => "cc.agent",
                 "agent_uri" => "entity://team-alpha/agent/just-a-name",
                 "cwd" => "/tmp"
               })
    end

    test "ignores legacy name prefix when validating stored flavor" do
      assert :ok =
               CcAgent.validate(%{
                 "class" => "cc.agent",
                 "agent_uri" => "entity://team-alpha/agent/curl_my-deepseek",
                 "cwd" => "/tmp"
               })
    end

    test "rejects missing cwd" do
      assert {:error, :missing_cwd} =
               CcAgent.validate(%{
                 "class" => "cc.agent",
                 "agent_uri" => "entity://team-alpha/agent/cc_x"
               })
    end
  end

  describe "instantiate/3" do
    test "spawns a PtyServer for the declared agent" do
      agent_uri_str = "entity://team-alpha/agent/cc_test-#{System.unique_integer([:positive])}"

      tmpl = %{
        "class" => "cc.agent",
        "agent_uri" => agent_uri_str,
        "cwd" => "/tmp"
      }

      workspace_uri = Ezagent.URI.new!("workspace://test")

      # codex round-6 HIGH-1 — `instantiate/3` returns the 3-element
      # `{:ok, uris, %{fresh?: _}}` form; a first spawn is `fresh?: true`.
      assert {:ok, [returned_uri], %{fresh?: true}} =
               CcAgent.instantiate("test-tmpl", tmpl, workspace_uri)

      assert URI.to_string(returned_uri) == agent_uri_str
    end

    test "produces BOTH the Agent Kind AND the PtyServer (V1 fix invariant)" do
      # V1 fix Allen 2026-05-21: instantiate is the sole producer of
      # the cc agent's runtime resources. After it returns:
      # 1. KindRegistry.lookup(agent_uri) must succeed — Agent Kind alive
      # 2. PtyServer.find_by_agent_uri(agent_uri) must succeed — PTY alive
      agent_uri_str = "entity://team-alpha/agent/cc_v1fix-#{System.unique_integer([:positive])}"
      agent_uri = Ezagent.URI.new!(agent_uri_str)

      tmpl = %{
        "class" => "cc.agent",
        "agent_uri" => agent_uri_str,
        "cwd" => "/tmp"
      }

      workspace_uri = Ezagent.URI.new!("workspace://test")

      # codex round-6 HIGH-1 — 3-element return; a first spawn is fresh.
      assert {:ok, [^agent_uri], %{fresh?: true}} =
               CcAgent.instantiate("t", tmpl, workspace_uri)

      assert {:ok, agent_pid} = Ezagent.KindRegistry.lookup(agent_uri),
             "Agent Kind must be alive after cc.agent.instantiate (V1 fix invariant)"

      assert is_pid(agent_pid)
      assert Process.alive?(agent_pid)

      assert {:ok, pty_pid} = Ezagent.Domain.Pty.lookup(agent_uri),
             "PtyServer must be alive after cc.agent.instantiate (V1 fix invariant)"

      assert is_pid(pty_pid)
      assert Process.alive?(pty_pid)
    end

    test "is idempotent — second call returns same URI without spawning a second PtyServer" do
      agent_uri_str = "entity://team-alpha/agent/cc_idem-#{System.unique_integer([:positive])}"
      uri = Ezagent.URI.new!(agent_uri_str)

      tmpl = %{
        "class" => "cc.agent",
        "agent_uri" => agent_uri_str,
        "cwd" => "/tmp"
      }

      workspace_uri = Ezagent.URI.new!("workspace://test")

      # codex round-6 HIGH-1 — first spawn is fresh, the idempotent
      # re-call adopts the already-live worker (`fresh?: false`).
      assert {:ok, [^uri], %{fresh?: true}} = CcAgent.instantiate("t", tmpl, workspace_uri)

      pids_before = list_pty_pids_for(agent_uri_str)
      assert length(pids_before) == 1

      assert {:ok, [^uri], %{fresh?: false}} = CcAgent.instantiate("t", tmpl, workspace_uri)

      pids_after = list_pty_pids_for(agent_uri_str)
      assert pids_after == pids_before
    end

    # codex round-8 HIGH-1 — when the Agent Kind already exists (a
    # worker THIS instantiate did NOT create — e.g. spawned directly by
    # a concurrent path), `instantiate/3` must return `fresh?: false`
    # WITHOUT starting a PTY sidecar. Adopting a foreign / orphaned
    # worker is the caller's decision; the Template Class must not
    # attach a sidecar to it.
    test "an already-started Agent Kind returns fresh?: false and starts NO PtyServer" do
      agent_uri_str =
        "entity://team-alpha/agent/cc_already-#{System.unique_integer([:positive])}"

      agent_uri = Ezagent.URI.new!(agent_uri_str)

      # Bring up ONLY the Agent Kind — directly, NOT via the template or
      # URI-derived flavor dispatch. This is the "worker this call did
      # not create" state: Kind alive, no PtyServer.
      assert {:ok, _pid} = Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: agent_uri})
      assert {:ok, _} = Ezagent.KindRegistry.lookup(agent_uri)

      refute Ezagent.Domain.Pty.alive?(agent_uri),
             "precondition: no PtyServer before instantiate"

      tmpl = %{
        "class" => "cc.agent",
        "agent_uri" => agent_uri_str,
        "cwd" => "/tmp"
      }

      workspace_uri = Ezagent.URI.new!("workspace://test")

      # The instantiate hits `spawn_for_local_pty` (Kind alive but PTY
      # absent, so the idempotency short-circuit does not fire), and
      # `ensure_agent_kind` reports `:already_started` → the fresh-check
      # gates the sidecar: `fresh?: false`, NO PTY.
      assert {:ok, [^agent_uri], %{fresh?: false}} =
               CcAgent.instantiate("t", tmpl, workspace_uri)

      refute Ezagent.Domain.Pty.alive?(agent_uri),
             "a rejected adoption must NOT start a PTY sidecar (codex round-8 HIGH-1)"

      assert list_pty_pids_for(agent_uri_str) == [],
             "no PtyServer process may exist for an already-started Agent Kind"
    end
  end

  describe "registry integration" do
    test "Template Class is registered at boot" do
      assert {:ok, Ezagent.PluginCc.Template.CcAgent} =
               Ezagent.TemplateRegistry.lookup("cc.agent")
    end
  end

  describe "validate/1 — Phase 7 completion PR-1 extended sandbox keys (SPEC §1.5 (c))" do
    test "legacy 3-key form still validates (backward compat)" do
      assert :ok =
               CcAgent.validate(%{
                 "class" => "cc.agent",
                 "agent_uri" => "entity://team-alpha/agent/cc_legacy",
                 "cwd" => "/tmp"
               })
    end

    test "extended form validates (config_dir is the universal neutral key)" do
      assert :ok =
               CcAgent.validate(%{
                 "class" => "cc.agent",
                 "agent_uri" => "entity://team-alpha/agent/cc_extended",
                 "cwd" => "/tmp",
                 "operator_settings_path" => "/sandbox/settings.json",
                 "operator_mcp_config_path" => "/sandbox/mcp.json",
                 # config_dir promotion (Allen 2026-06-03): universal,
                 # flavor-neutral key (was "claude_config_dir").
                 "config_dir" => "/sandbox/.claude",
                 "api_key_helper" => "/sandbox/key-helper.sh"
               })
    end

    test "a non-string sandbox key is rejected" do
      assert {:error, {:invalid_sandbox_key, "config_dir", _}} =
               CcAgent.validate(%{
                 "class" => "cc.agent",
                 "agent_uri" => "entity://team-alpha/agent/cc_bad",
                 "cwd" => "/tmp",
                 "config_dir" => 123
               })
    end

    # config_dir promotion (Allen 2026-06-03) — codex P2 closure. A stale
    # `"claude_config_dir"` key (from a persisted/hand-written template) must
    # FAIL LOUD, not be silently ignored (which would spawn the agent without
    # its isolated config dir / CLAUDE_CONFIG_DIR). No back-compat shim —
    # `feedback_let_it_crash_no_workarounds`.
    test "a stale claude_config_dir key fails loud (no silent fallback)" do
      assert {:error, {:stale_config_dir_key, "claude_config_dir", _}} =
               CcAgent.validate(%{
                 "class" => "cc.agent",
                 "agent_uri" => "entity://team-alpha/agent/cc_stale",
                 "cwd" => "/tmp",
                 "claude_config_dir" => "/sandbox/.claude"
               })
    end
  end

  # codex HIGH-2 — `assemble_settings_mcp_args/3` returns an argv LIST
  # (each flag + each path a SEPARATE element) handed verbatim to
  # `:exec.run/2`'s no-shell argv form. These tests are adversarial:
  # an operator-controlled `operator_settings_path` /
  # `operator_mcp_config_path` containing a space, a literal
  # ` --settings /tmp/x.json`, or shell metacharacters MUST NOT become
  # a separate flag or execute a shell command, and the mandatory
  # safety `--settings` MUST stay last-wins + non-overridable.
  describe "assemble_settings_mcp_args/3 — argv-safe adversarial (codex HIGH-2)" do
    @mandatory "/priv/claude-pty-settings.json"
    @bridge "/run/esr-bridge.mcp.json"

    # Extract the value(s) following each occurrence of `flag` in the
    # argv list. Because the list is `[flag, value, flag, value, ...]`,
    # a value is whatever element directly follows a flag element.
    defp values_for(argv, flag) do
      argv
      |> Enum.with_index()
      |> Enum.filter(fn {el, _i} -> el == flag end)
      |> Enum.map(fn {_el, i} -> Enum.at(argv, i + 1) end)
    end

    test "no operator keys: argv has only the mandatory --settings + bridge --mcp-config" do
      argv = CcAgent.assemble_settings_mcp_args(@mandatory, @bridge, %{})

      assert argv == ["--settings", @mandatory, "--mcp-config", @bridge]
    end

    test "the mandatory safety --settings is ALWAYS the LAST --settings (last-wins)" do
      hostile = %{"operator_settings_path" => "/hostile/settings.json"}
      argv = CcAgent.assemble_settings_mcp_args(@mandatory, @bridge, hostile)

      settings_values = values_for(argv, "--settings")

      assert settings_values == ["/hostile/settings.json", @mandatory],
             "operator --settings must precede the mandatory safety --settings"

      assert List.last(settings_values) == @mandatory,
             "the mandatory remoteControlAtStartup:false file must be LAST so it wins"
    end

    test "the trusted esr-bridge --mcp-config is never replaced by an operator one" do
      hostile = %{"operator_mcp_config_path" => "/hostile/mcp.json"}
      argv = CcAgent.assemble_settings_mcp_args(@mandatory, @bridge, hostile)

      mcp_values = values_for(argv, "--mcp-config")

      assert @bridge in mcp_values,
             "the trusted esr-bridge --mcp-config must always be present"

      assert "/hostile/mcp.json" in mcp_values,
             "operator --mcp-config is additive, not a replacement"
    end

    test "(a) an operator path containing a SPACE stays ONE argv element" do
      # A space in a shell string would split into two arguments. In
      # the argv list it must remain a single, intact element.
      spacey = "/tmp/my settings.json"

      argv =
        CcAgent.assemble_settings_mcp_args(@mandatory, @bridge, %{
          "operator_settings_path" => spacey
        })

      assert spacey in argv,
             "the spaced operator path must survive intact as one argv element"

      # It is NOT split — neither half appears as a standalone element.
      refute "/tmp/my" in argv
      refute "settings.json" in argv
    end

    test "(b) an operator path with a literal ` --settings /tmp/x.json` cannot inject a flag" do
      # The classic flag-injection: a value that, space-joined, would
      # introduce a LATER --settings and defeat the last-wins safety
      # guarantee. In argv form the whole string is ONE element.
      injected = "/tmp/mcp.json --settings /tmp/hostile-settings.json"

      argv =
        CcAgent.assemble_settings_mcp_args(@mandatory, @bridge, %{
          "operator_mcp_config_path" => injected
        })

      # The injected string is delivered verbatim as a single
      # --mcp-config value — it is NOT parsed as a flag.
      assert injected in values_for(argv, "--mcp-config"),
             "the injection string must be one --mcp-config value, intact"

      # The hostile path NEVER became a --settings value. The only
      # --settings value is the mandatory safety file (no operator
      # --settings key was set).
      assert values_for(argv, "--settings") == [@mandatory],
             "no operator value may introduce an extra --settings flag"

      assert List.last(values_for(argv, "--settings")) == @mandatory,
             "the mandatory safety --settings remains last-wins"

      # `/tmp/hostile-settings.json` is NOT a standalone argv element —
      # it is buried inside the single injected string, inert.
      refute "/tmp/hostile-settings.json" in argv
    end

    test "(b') a --settings injection via operator_settings_path still cannot win over safety" do
      injected = "/tmp/op.json --settings /tmp/evil.json"

      argv =
        CcAgent.assemble_settings_mcp_args(@mandatory, @bridge, %{
          "operator_settings_path" => injected
        })

      settings_values = values_for(argv, "--settings")

      # Exactly two --settings values: the (intact, nonsense) operator
      # string FIRST and the mandatory safety file LAST. The buried
      # `/tmp/evil.json` never became its own --settings value.
      assert settings_values == [injected, @mandatory],
             "the injection cannot add a third, later --settings"

      assert List.last(settings_values) == @mandatory,
             "the mandatory remoteControlAtStartup:false file still wins"

      refute "/tmp/evil.json" in argv
    end

    test "(c) shell metacharacters in an operator path stay inert (no command execution)" do
      # `;`, `$(...)`, backticks and `&&` would be interpreted by a
      # shell. In argv form there is NO shell — each is delivered as a
      # literal character inside a single argv element.
      for metachar_path <- [
            "/tmp/x.json; rm -rf /tmp/pwned",
            "/tmp/x.json$(touch /tmp/pwned)",
            "/tmp/x.json`touch /tmp/pwned`",
            "/tmp/x.json && touch /tmp/pwned"
          ] do
        argv =
          CcAgent.assemble_settings_mcp_args(@mandatory, @bridge, %{
            "operator_settings_path" => metachar_path
          })

        assert metachar_path in argv,
               "the metachar path must survive intact as one argv element: #{metachar_path}"

        # The settings sequence is still exactly [operator, mandatory].
        assert values_for(argv, "--settings") == [metachar_path, @mandatory],
               "metachars must not create extra --settings flags"

        assert List.last(values_for(argv, "--settings")) == @mandatory,
               "the mandatory safety --settings still wins"

        # No fragment of the metachar payload leaked out as its own
        # argv element — the whole thing is one inert string.
        refute "rm" in argv
        refute "touch" in argv
      end
    end
  end

  defp list_pty_pids_for(agent_uri_str) do
    Ezagent.Domain.Pty.Server.list_agents()
    |> Enum.filter(fn a -> URI.to_string(a.agent_uri) == agent_uri_str end)
    |> Enum.map(& &1.pid)
  end

  # PTY-orphan-restart 2026-05-26 — `ensure_subprocess_alive/2` is the
  # respawn hook `Ezagent.ActionSet.Sandbox.post_init/2` calls after a
  # phx restart when the Agent Kind has been rehydrated but the
  # claude PtyServer has not been re-spawned.
  describe "ensure_subprocess_alive/2 — PTY-orphan-restart 2026-05-26" do
    setup do
      Application.put_env(:ezagent_core, :sqlite_path, "/tmp/ezagent_test_pty_orphan.db")

      ws_uri =
        URI.new!(
          "workspace://" <>
            "ws_pty_orphan_#{:erlang.unique_integer([:positive, :monotonic])}"
        )

      {:ok, _pid} = Ezagent.Workspace.spawn_workspace(ws_uri.host)
      cwd = System.tmp_dir!()
      :ok = File.mkdir_p(cwd)

      uri =
        URI.new!(
          "entity://#{ws_uri.host}/agent/cc_eternal_#{:erlang.unique_integer([:positive, :monotonic])}"
        )

      %{uri: uri, workspace_uri: ws_uri, cwd: cwd}
    end

    test "returns :ok immediately when PtyServer is already alive", %{
      uri: uri,
      cwd: cwd,
      workspace_uri: ws
    } do
      tmpl = %{
        "class" => "cc.agent",
        "agent_uri" => URI.to_string(uri),
        "cwd" => cwd
      }

      assert {:ok, [_returned_uri], %{fresh?: true}} = CcAgent.instantiate("t", tmpl, ws)
      assert Ezagent.Domain.Pty.alive?(uri)

      # Live PtyServer → respawn callback is a no-op.
      assert :ok = CcAgent.ensure_subprocess_alive(uri, tmpl)

      # Cleanup: terminate the Agent Kind + the PtyServer.
      _ = Ezagent.Kind.terminate(uri)
    end

    test "returns {:error, :missing_cwd_in_respawn_data} when respawn_data has no cwd", %{
      uri: uri
    } do
      # The cwd-less path is the structural failure case; an agent
      # whose sandbox slice was corrupted should NOT silently use a
      # default cwd.
      assert {:error, {:missing_cwd_in_respawn_data, ^uri}} =
               CcAgent.ensure_subprocess_alive(uri, %{})
    end

    test "rejects invalid args" do
      assert {:error, :invalid_args} = CcAgent.ensure_subprocess_alive("not a URI", %{})

      assert {:error, :invalid_args} =
               CcAgent.ensure_subprocess_alive(URI.new!("entity://x/agent/cc_y"), "not a map")
    end
  end

  # config_dir promotion (Allen 2026-06-03) — PR-F lazy migration. Agents
  # SEEDED before the rename persisted `respawn_template_data` carrying the
  # OLD `"claude_config_dir"` key. On a cold restart `ensure_subprocess_alive/2`
  # feeds that persisted data straight into the build path whose
  # `reject_stale_config_dir_data_key!/1` FAIL-LOUDS → the agent crash-loops
  # and can never respawn its PTY (the 传话游戏 relay "no reply" bug,
  # 2026-06-04). The fix migrates the legacy key forward AT the rehydration
  # boundary so the fail-loud reject stays intact for fresh/validate paths
  # while pre-rename persisted agents boot. Regression test
  # (feedback_e2e_failure_earns_unit_test) for the pure migrator.
  describe "migrate_legacy_config_dir_key/1 — PR-F cold-restart forward migration" do
    test "renames a lone legacy claude_config_dir → config_dir (and drops the legacy key)" do
      migrated =
        CcAgent.migrate_legacy_config_dir_key(%{"claude_config_dir" => "/sandbox/.claude"})

      assert migrated == %{"config_dir" => "/sandbox/.claude"}
      # the migrated map must NOT trip the stale-key fail-loud reject.
      refute Map.has_key?(migrated, "claude_config_dir")
    end

    test "preserves the new config_dir and drops legacy when BOTH are present" do
      migrated =
        CcAgent.migrate_legacy_config_dir_key(%{
          "claude_config_dir" => "/old/.claude",
          "config_dir" => "/new/.claude"
        })

      # the current contract key wins; the legacy duplicate is removed.
      assert migrated == %{"config_dir" => "/new/.claude"}
    end

    test "leaves a map with only the new config_dir unchanged" do
      tmpl = %{"config_dir" => "/new/.claude", "cwd" => "/work"}
      assert CcAgent.migrate_legacy_config_dir_key(tmpl) == tmpl
    end

    test "leaves a map with neither key unchanged" do
      tmpl = %{"cwd" => "/work", "class" => "cc.agent"}
      assert CcAgent.migrate_legacy_config_dir_key(tmpl) == tmpl
    end
  end

  # PTY-orphan-restart 2026-05-26 round-2 (codex finding #1) — the
  # demand-spawn race window. If a chat-router demand-spawn brings up
  # the Agent Kind WITHOUT a PtyServer (the chat router doesn't know
  # about PTY), the subsequent Workspace.Loader instantiate must
  # bring the PTY up. The pre-round-2 codex round-8 fix short-
  # circuited too early. Round-2 closes the gap WHILE preserving
  # round-8's foreign-Kind-adoption refusal via a workspace-segment
  # ownership gate.
  describe "instantiate :already_started branch — codex round-2 demand-spawn fix" do
    setup do
      Application.put_env(:ezagent_core, :sqlite_path, "/tmp/ezagent_test_pty_orphan_demand.db")

      ws_uri =
        URI.new!(
          "workspace://" <>
            "ws_demand_#{:erlang.unique_integer([:positive, :monotonic])}"
        )

      {:ok, _pid} = Ezagent.Workspace.spawn_workspace(ws_uri.host)
      cwd = System.tmp_dir!()
      :ok = File.mkdir_p(cwd)

      # IMPORTANT: agent_uri's workspace segment MUST match ws_uri.host
      # for the ownership gate to allow PTY spawn (this is the "we
      # own this agent" case — Workspace.Loader path).
      uri =
        URI.new!(
          "entity://#{ws_uri.host}/agent/cc_demand_#{:erlang.unique_integer([:positive, :monotonic])}"
        )

      %{uri: uri, workspace_uri: ws_uri, cwd: cwd}
    end

    test "Kind-alive-without-PTY in OWNING workspace → PTY gets spawned", %{
      uri: agent_uri,
      workspace_uri: ws_uri,
      cwd: cwd
    } do
      # Simulate the demand-spawn: bring up only the Agent Kind, no PTY.
      assert {:ok, _pid} = Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: agent_uri})
      assert {:ok, _} = Ezagent.KindRegistry.lookup(agent_uri)
      refute Ezagent.Domain.Pty.alive?(agent_uri), "precondition: no PtyServer"

      tmpl = %{
        "class" => "cc.agent",
        "agent_uri" => URI.to_string(agent_uri),
        "cwd" => cwd
      }

      # workspace_uri MATCHES the agent's workspace segment → ownership
      # gate allows the PTY spawn.
      assert {:ok, [_], %{fresh?: false}} = CcAgent.instantiate("t", tmpl, ws_uri)

      assert Ezagent.Domain.Pty.alive?(agent_uri),
             "PTY must be spawned for an owned-workspace adopted Kind " <>
               "(codex round-2 finding #1)"

      # Cleanup
      _ = Ezagent.Kind.terminate(agent_uri)
    end
  end
end
