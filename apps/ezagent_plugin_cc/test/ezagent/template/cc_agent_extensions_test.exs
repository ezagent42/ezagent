defmodule Ezagent.PluginCc.Template.CcAgentExtensionsTest do
  @moduledoc """
  PR3 2026-05-24 (Allen) — cc Template Class implementation of the 3
  `Ezagent.Kind.Template` extension callbacks:

  - `list_extensions/1` — scan `<config_dir>/.claude/plugins/*` for
    Claude Code plugin bundles (recognized by `.claude-plugin/plugin.json`).
  - `toggle_extension/3` — TOGGLE-OFF rm-rf's the bundle dir.
    TOGGLE-ON is stubbed (`{:error, :install_from_source_not_implemented}`)
    pending marketplace integration.
  - `destroy_config_dir/2` — `rm -rf <config_dir>` after verifying the
    path matches `agent_config_dir/1` (defense-in-depth path lock).

  Plus `create_agent_config_dir/2` — the helper called by
  `instantiate/3` BEFORE PTY launch to copy the template's reference
  dir into the per-agent location.
  """

  use ExUnit.Case, async: true

  alias Ezagent.PluginCc.Template.CcAgent

  defp uniq, do: System.unique_integer([:positive])

  defp make_tmpdir(suffix) do
    dir = Path.join(System.tmp_dir!(), "cc-ext-#{suffix}-#{uniq()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp write_plugin_manifest(plugins_dir, ext_id, name, description) do
    bundle_dir = Path.join([plugins_dir, ext_id])
    manifest_dir = Path.join(bundle_dir, ".claude-plugin")
    File.mkdir_p!(manifest_dir)
    File.write!(Path.join(manifest_dir, "plugin.json"), Jason.encode!(%{
      "name" => name,
      "description" => description,
      "version" => "1.0.0"
    }))

    bundle_dir
  end

  describe "list_extensions/1" do
    test "scans <config_dir>/.claude/plugins/* and reads each manifest" do
      config_dir = make_tmpdir("list-ok")
      plugins_dir = Path.join([config_dir, ".claude", "plugins"])
      File.mkdir_p!(plugins_dir)

      write_plugin_manifest(plugins_dir, "alpha-ext", "Alpha Extension", "Does alpha things")
      write_plugin_manifest(plugins_dir, "beta-ext", "Beta Extension", "Does beta things")

      assert {:ok, exts} = CcAgent.list_extensions(config_dir)

      ids = Enum.map(exts, & &1.id) |> Enum.sort()
      assert ids == ["alpha-ext", "beta-ext"]

      alpha = Enum.find(exts, &(&1.id == "alpha-ext"))
      assert alpha.name == "Alpha Extension"
      assert alpha.description == "Does alpha things"
      assert alpha.enabled? == true
    end

    test "returns empty list when plugins dir does not exist" do
      config_dir = make_tmpdir("list-empty")

      assert {:ok, []} = CcAgent.list_extensions(config_dir)
    end

    test "silently skips dirs without a plugin.json manifest (operator drop-ins ignored)" do
      config_dir = make_tmpdir("list-skip")
      plugins_dir = Path.join([config_dir, ".claude", "plugins"])
      File.mkdir_p!(plugins_dir)

      # A real bundle
      write_plugin_manifest(plugins_dir, "real", "Real", "Real")
      # A directory without a manifest (operator's stray scratch dir)
      File.mkdir_p!(Path.join(plugins_dir, "scratch"))
      # A non-dir entry
      File.write!(Path.join(plugins_dir, "notes.txt"), "ignore me")

      assert {:ok, exts} = CcAgent.list_extensions(config_dir)
      assert Enum.map(exts, & &1.id) == ["real"]
    end

    test "rejects non-binary input" do
      assert {:error, :invalid_config_dir} = CcAgent.list_extensions(nil)
      assert {:error, :invalid_config_dir} = CcAgent.list_extensions(:atom)
    end
  end

  describe "toggle_extension/3 — toggle-off" do
    test "rm -rf's the bundle dir for enabled? = false" do
      config_dir = make_tmpdir("toggle-off")
      plugins_dir = Path.join([config_dir, ".claude", "plugins"])
      File.mkdir_p!(plugins_dir)
      bundle = write_plugin_manifest(plugins_dir, "to-remove", "ToRemove", "x")

      assert File.dir?(bundle)
      assert :ok = CcAgent.toggle_extension(config_dir, "to-remove", false)
      refute File.dir?(bundle)
    end

    test "toggle-off on a non-existent bundle is :ok (idempotent)" do
      config_dir = make_tmpdir("toggle-off-absent")
      # No plugins dir at all → toggle-off of a non-existent bundle
      # succeeds (rm_rf returns {:ok, []}).
      assert :ok = CcAgent.toggle_extension(config_dir, "ghost", false)
    end
  end

  describe "toggle_extension/3 — toggle-on is stubbed" do
    test "returns :install_from_source_not_implemented" do
      config_dir = make_tmpdir("toggle-on")

      assert {:error, :install_from_source_not_implemented} =
               CcAgent.toggle_extension(config_dir, "anything", true)
    end
  end

  describe "toggle_extension/3 — path safety (defense in depth)" do
    test "rejects extension_id with path-traversal (../)" do
      config_dir = make_tmpdir("toggle-traversal")
      assert {:error, :unsafe_extension_path} =
               CcAgent.toggle_extension(config_dir, "../../etc", false)
    end

    test "rejects extension_id with absolute-path prefix" do
      config_dir = make_tmpdir("toggle-abs")
      # An absolute path string in extension_id — Path.join still
      # composes it but Path.expand reveals it's outside the plugins
      # dir, so safe_extension_path? rejects.
      assert {:error, :unsafe_extension_path} =
               CcAgent.toggle_extension(config_dir, "/etc/passwd", false)
    end
  end

  describe "destroy_config_dir/2 — path lock" do
    test "rm -rf's the dir when path matches agent_config_dir/1" do
      agent_uri = URI.new!("entity://team-alpha/agent/cc_destroy-test-#{uniq()}")
      canonical = CcAgent.agent_config_dir(agent_uri)
      File.mkdir_p!(canonical)
      File.write!(Path.join(canonical, "marker"), "x")
      on_exit(fn -> File.rm_rf(canonical) end)

      assert File.dir?(canonical)
      assert :ok = CcAgent.destroy_config_dir(agent_uri, canonical)
      refute File.dir?(canonical)
    end

    test "REJECTS mismatched paths (e.g. someone passes / or /etc)" do
      agent_uri = URI.new!("entity://team-alpha/agent/cc_lock-test-#{uniq()}")

      assert {:error, {:path_mismatch, _}} =
               CcAgent.destroy_config_dir(agent_uri, "/etc")

      assert {:error, {:path_mismatch, _}} =
               CcAgent.destroy_config_dir(agent_uri, "/tmp/random")
    end

    test "rejects invalid args" do
      assert {:error, :invalid_args} = CcAgent.destroy_config_dir(nil, "/tmp/x")
      assert {:error, :invalid_args} = CcAgent.destroy_config_dir("not_a_uri", "/tmp/x")
    end
  end

  describe "create_agent_config_dir/2" do
    test "copies the reference dir to the per-agent location + chmods" do
      reference = make_tmpdir("cc-ref")
      File.write!(Path.join(reference, ".credentials.json"), "{}")
      File.write!(Path.join(reference, "settings.json"), "{}")

      agent_uri = URI.new!("entity://team-alpha/agent/cc_create-test-#{uniq()}")
      # config_dir promotion (Allen 2026-06-03): cc reads the universal,
      # flavor-neutral "config_dir" data key (was "claude_config_dir").
      # PR-3: the per-agent TARGET is domain-allocated + provided as
      # "allocated_config_dir"; the plugin materializes the reference INTO it.
      tmpl = %{
        "config_dir" => reference,
        "allocated_config_dir" => CcAgent.agent_config_dir(agent_uri)
      }

      assert {:ok, dir} = CcAgent.create_agent_config_dir(agent_uri, tmpl)
      on_exit(fn -> File.rm_rf(dir) end)

      assert dir == CcAgent.agent_config_dir(agent_uri)
      assert File.dir?(dir)
      assert File.exists?(Path.join(dir, ".credentials.json"))
      assert File.exists?(Path.join(dir, "settings.json"))

      {:ok, stat} = File.stat(dir)
      # Lower 9 bits = perms; 0o700 = owner rwx, group/other none
      assert Bitwise.band(stat.mode, 0o777) == 0o700

      {:ok, creds_stat} = File.stat(Path.join(dir, ".credentials.json"))
      assert Bitwise.band(creds_stat.mode, 0o777) == 0o600
    end

    test "is IDEMPOTENT — re-call on existing dir is a no-op success" do
      reference = make_tmpdir("cc-idem-ref")
      File.write!(Path.join(reference, ".credentials.json"), "{}")

      agent_uri = URI.new!("entity://team-alpha/agent/cc_idem-test-#{uniq()}")
      tmpl = %{
        "config_dir" => reference,
        "allocated_config_dir" => CcAgent.agent_config_dir(agent_uri)
      }

      assert {:ok, dir1} = CcAgent.create_agent_config_dir(agent_uri, tmpl)
      on_exit(fn -> File.rm_rf(dir1) end)

      # Drop a marker so we can detect a re-copy (which would wipe it).
      File.write!(Path.join(dir1, "user-added-marker"), "x")

      assert {:ok, dir2} = CcAgent.create_agent_config_dir(agent_uri, tmpl)
      assert dir1 == dir2
      assert File.exists?(Path.join(dir1, "user-added-marker")),
             "re-call must NOT re-copy from reference (would wipe live state)"
    end

    test "returns {:ok, nil} when template has no config_dir" do
      agent_uri = URI.new!("entity://team-alpha/agent/cc_no-ref-#{uniq()}")
      tmpl = %{"agent_uri" => URI.to_string(agent_uri), "cwd" => "/tmp", "class" => "cc.agent"}

      assert {:ok, nil} = CcAgent.create_agent_config_dir(agent_uri, tmpl)
    end

    test "fails loud on a stale claude_config_dir data key (codex P2 — loader bypasses validate)" do
      # Workspace.Loader.invoke_template/2 calls instantiate/3 (→
      # create_agent_config_dir/2) WITHOUT running validate/1, so a stale
      # data key must fail loud HERE too, not silently spawn without the
      # isolated config dir. feedback_let_it_crash_no_workarounds.
      agent_uri = URI.new!("entity://team-alpha/agent/cc_stale-key-#{uniq()}")
      tmpl = %{"claude_config_dir" => "/old/.claude"}

      assert_raise ArgumentError, ~r/stale `claude_config_dir` data key/, fn ->
        CcAgent.create_agent_config_dir(agent_uri, tmpl)
      end
    end

    test "a present-but-malformed config_dir fails loud, NOT silently dropped (codex P2)" do
      # The loader path bypasses validate/1; a present `""`/non-binary
      # config_dir must fail loud here rather than be treated as absent
      # (which would spawn without CLAUDE_CONFIG_DIR on the operator home).
      agent_uri = URI.new!("entity://team-alpha/agent/cc_malformed-#{uniq()}")

      assert {:error, {:invalid_config_dir, ""}} =
               CcAgent.create_agent_config_dir(agent_uri, %{"config_dir" => ""})

      assert {:error, {:invalid_config_dir, 123}} =
               CcAgent.create_agent_config_dir(agent_uri, %{"config_dir" => 123})
    end

    test "returns error if reference dir doesn't exist" do
      agent_uri = URI.new!("entity://team-alpha/agent/cc_missing-ref-#{uniq()}")

      tmpl = %{
        "config_dir" => "/nonexistent/path/123",
        "allocated_config_dir" => CcAgent.agent_config_dir(agent_uri)
      }

      assert {:error, {:reference_dir_missing, "/nonexistent/path/123"}} =
               CcAgent.create_agent_config_dir(agent_uri, tmpl)
    end

    test "fails loud when a config_dir reference is present but the TARGET was not allocated (PR-3)" do
      # Every spawn seam routes through provision_and_instantiate/4, which injects
      # "allocated_config_dir". An absent target means an un-provisioned/direct
      # caller — the plugin must NOT self-allocate a path (that scatter is the bug
      # PR-3 removes). feedback_let_it_crash_no_workarounds.
      agent_uri = URI.new!("entity://team-alpha/agent/cc_unallocated-#{uniq()}")
      reference = make_tmpdir("cc-unalloc-ref")

      assert {:error, :config_dir_not_allocated} =
               CcAgent.create_agent_config_dir(agent_uri, %{"config_dir" => reference})
    end

    test "materializes into a pre-allocated (empty) TARGET dir — the production path (PR-3)" do
      # Simulates ConfigDir.allocate/2 having already created the target (mkdir +
      # chmod 700, no marker) BEFORE the plugin materializes the reference into it.
      reference = make_tmpdir("cc-prealloc-ref")
      File.write!(Path.join(reference, ".credentials.json"), "{}")

      agent_uri = URI.new!("entity://team-alpha/agent/cc_prealloc-#{uniq()}")
      target = CcAgent.agent_config_dir(agent_uri)
      File.mkdir_p!(target)
      File.chmod!(target, 0o700)
      on_exit(fn -> File.rm_rf(target) end)

      tmpl = %{"config_dir" => reference, "allocated_config_dir" => target}

      assert {:ok, ^target} = CcAgent.create_agent_config_dir(agent_uri, tmpl)
      assert File.exists?(Path.join(target, ".credentials.json"))
      assert File.exists?(Path.join(target, ".ezagent-config-complete"))
    end

    test "marker-absent target with creds: preserve user login + FILL missing reference content (PR-B / codex P2)" do
      # #17 PR-B: the user logged in (claude wrote .credentials.json) into a
      # marker-absent dir. materialize MUST (a) NEVER destroy the real login, AND
      # (b) NOT bless a possibly-incomplete tree — it overlays the user files on a
      # fresh reference stage so missing reference content (e.g. .claude/plugins) is
      # filled while user state wins (codex review P2).
      reference = make_tmpdir("cc-pr-b-ref")
      File.write!(Path.join(reference, ".credentials.json"), ~s/{"claudeAiOauth":"REFERENCE-stale"}/)
      File.write!(Path.join(reference, "settings.json"), ~s/{"from":"reference"}/)
      plugin_dir = Path.join([reference, ".claude", "plugins", "demo"])
      File.mkdir_p!(plugin_dir)
      File.write!(Path.join(plugin_dir, "plugin.json"), ~s/{"name":"demo"}/)

      agent_uri = URI.new!("entity://team-alpha/agent/cc_login-preserve-#{uniq()}")
      target = CcAgent.agent_config_dir(agent_uri)
      File.mkdir_p!(target)
      # the user's real login — present, but NO completion marker + NO other content
      user_creds = ~s/{"claudeAiOauth":"USER-REAL-LOGIN"}/
      File.write!(Path.join(target, ".credentials.json"), user_creds)
      refute File.exists?(Path.join(target, ".ezagent-config-complete"))
      on_exit(fn -> File.rm_rf(target) end)

      tmpl = %{"config_dir" => reference, "allocated_config_dir" => target}

      assert {:ok, ^target} = CcAgent.create_agent_config_dir(agent_uri, tmpl)
      # (a) the user's credential is intact (NOT overwritten by the reference's stale one)
      assert File.read!(Path.join(target, ".credentials.json")) == user_creds
      # (b) missing reference content was FILLED (no incomplete config — codex P2)
      assert File.read!(Path.join(target, "settings.json")) == ~s/{"from":"reference"}/
      assert File.exists?(Path.join([target, ".claude", "plugins", "demo", "plugin.json"]))
      # and the dir is now stamped complete so future spawns are idempotent
      assert File.exists?(Path.join(target, ".ezagent-config-complete"))
    end
  end

  describe "agent_config_dir/1 — canonical path builder" do
    test "produces a workspace-scoped per-agent path" do
      uri = URI.new!("entity://team-alpha/agent/cc_foo")
      dir = CcAgent.agent_config_dir(uri)
      assert String.ends_with?(dir, "/team-alpha/cc_foo")
      assert String.contains?(dir, "cc-agents")
    end

    test "extracts workspace + name correctly from team-alpha workspace" do
      uri = URI.new!("entity://team-alpha/agent/cc_bar")
      dir = CcAgent.agent_config_dir(uri)
      assert String.ends_with?(dir, "/team-alpha/cc_bar")
    end
  end
end
