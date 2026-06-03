defmodule Ezagent.PluginCc.Template.CcAgentCloneFromTest do
  @moduledoc """
  Agent-duplicate-simple SPEC (Allen 2026-05-25) — the cc-side half of
  the `--from <source-uri>` flag on `mix ezagent.agent.create`.

  The workspace action body (`Behavior.Workspace.:create_agent`) resolves
  the source agent's `config_dir_path` via a `sandbox.read` dispatch and
  threads it into the template under the universal `"config_dir"` key. The cc
  Template Class's existing `create_agent_config_dir/2` then does a
  `File.cp_r/2` from that source dir into the new agent's per-agent
  location.

  This test exercises ONLY the filesystem-copy half:

    - happy path: source dir contents reproduced under the target's
      `agent_config_dir/1` path file-by-file (incl. perms);
    - deep-copy independence: mutating the source AFTER the clone does
      NOT affect the target (proves a true cp_r, not a symlink / hard
      reference).

  The dispatch-side path (cap-deny on source → `:source_not_readable`,
  no fs ops on denial) is covered in
  `apps/ezagent_domain_workspace/test/integration/create_agent_dispatch_test.exs`.
  """

  use ExUnit.Case, async: true

  alias Ezagent.PluginCc.Template.CcAgent

  defp uniq, do: System.unique_integer([:positive])

  defp make_source_dir do
    dir = Path.join(System.tmp_dir!(), "cc-clone-src-#{uniq()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp cleanup_target(agent_uri) do
    on_exit(fn -> File.rm_rf(CcAgent.agent_config_dir(agent_uri)) end)
  end

  describe "create_agent_config_dir/2 with source config_dir as reference (clone happy path)" do
    test "reproduces source's files at the target's agent_config_dir path" do
      # Simulate the source agent's per-agent config_dir contents — the
      # standard `.credentials.json` (operator API key) + an installed
      # plugin bundle under `.claude/plugins/`.
      source = make_source_dir()
      File.write!(Path.join(source, ".credentials.json"), ~s/{"key": "sk-source-1234"}/)

      plugin_manifest = Path.join([source, ".claude", "plugins", "demo-plugin", ".claude-plugin"])
      File.mkdir_p!(plugin_manifest)

      File.write!(
        Path.join(plugin_manifest, "plugin.json"),
        ~s/{"name": "demo", "description": "src-plugin", "version": "1.0.0"}/
      )

      # The cc workspace action threads source's per-agent dir as
      # the universal `config_dir` key — that is the existing "reference
      # dir to copy at spawn" key the cc Template Class reads.
      # config_dir promotion (Allen 2026-06-03): universal neutral key.
      target_uri = URI.new!("entity://agent/system/cc_clone-target-#{uniq()}")
      cleanup_target(target_uri)
      tmpl = %{"config_dir" => source}

      assert {:ok, target} = CcAgent.create_agent_config_dir(target_uri, tmpl)

      # Target ends up at the canonical agent_config_dir path.
      assert target == CcAgent.agent_config_dir(target_uri)
      assert File.dir?(target)

      # File-by-file: credentials are present + match source content.
      assert File.read!(Path.join(target, ".credentials.json")) ==
               ~s/{"key": "sk-source-1234"}/

      # Plugin bundle nested-dir structure was reproduced.
      target_manifest =
        Path.join([target, ".claude", "plugins", "demo-plugin", ".claude-plugin", "plugin.json"])

      assert File.exists?(target_manifest)
      assert File.read!(target_manifest) =~ "src-plugin"

      # cp_r preserved the credentials chmod-600 convention (the cc
      # Template Class applies it explicitly post-copy).
      {:ok, creds_stat} = File.stat(Path.join(target, ".credentials.json"))
      assert Bitwise.band(creds_stat.mode, 0o777) == 0o600
    end

    test "deep-copy independence: mutating source AFTER clone does NOT affect target" do
      source = make_source_dir()
      File.write!(Path.join(source, "user-data.txt"), "before-clone")

      target_uri = URI.new!("entity://agent/system/cc_indep-target-#{uniq()}")
      cleanup_target(target_uri)
      tmpl = %{"config_dir" => source}

      assert {:ok, target} = CcAgent.create_agent_config_dir(target_uri, tmpl)
      assert File.read!(Path.join(target, "user-data.txt")) == "before-clone"

      # Mutate the source AFTER the clone — target must be unaffected
      # (this is what proves cp_r vs a symlink / bind mount).
      File.write!(Path.join(source, "user-data.txt"), "after-source-mutation")
      File.write!(Path.join(source, "new-file-in-source.txt"), "added-post-clone")

      assert File.read!(Path.join(target, "user-data.txt")) == "before-clone",
             "target must NOT pick up source mutation made after clone"

      refute File.exists?(Path.join(target, "new-file-in-source.txt")),
             "target must NOT pick up files added to source after clone"
    end
  end
end
