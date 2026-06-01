defmodule EzagentPluginAutoservice.CinnoxRuntime do
  @moduledoc """
  Runtime materialization helpers for the vendored CINNOX assets.

  Phase 1's reproducibility goal is: a clean checkout + one seed command
  should recreate the demo, with no hidden dependence on tree-external
  files under `~/...` or the ad-hoc `cinnox-data/` repo-root snapshot.

  We therefore vendor the authoritative assets into `priv/cinnox/` and at
  seed time copy them into a **per-agent working directory** that claude
  can operate in directly.
  """

  alias EzagentPluginAutoservice.CinnoxAssets

  @doc "Persistent working dir for the cinnox cc slow agent."
  def cc_slow_work_dir do
    Path.join([Ezagent.Home.profile_dir(), "cc-agents", "cinnox", "cc_slow-work"])
  end

  @doc "Persistent location for the vendored kb.db file."
  def kb_db_runtime_path do
    Path.join([Ezagent.Home.profile_dir(), "cc-agents", "cinnox", "kb.db"])
  end

  @doc "Persistent location for the vendored kb_search MCP server script."
  def kb_mcp_script_runtime_path do
    Path.join([Ezagent.Home.profile_dir(), "cc-agents", "cinnox", "kb_search_mcp.py"])
  end

  @doc "Persistent location for the vendored query_expansion module."
  def kb_query_expansion_runtime_path do
    Path.join([Ezagent.Home.profile_dir(), "cc-agents", "cinnox", "query_expansion.py"])
  end

  @doc "Persistent mcp.json consumed by cc via operator_mcp_config_path."
  def kb_mcp_config_runtime_path do
    Path.join([Ezagent.Home.profile_dir(), "cc-agents", "cinnox", "kb_search.mcp.json"])
  end

  @doc """
  Materialize the vendored CINNOX cc workspace and kb-search MCP sidecar.

  Idempotent: rewrites generated files in place, preserving the target
  directory structure. If the user edits generated files under
  `~/.ezagent/default/cc-agents/cinnox/` manually, a re-seed intentionally
  overwrites them — `priv/` is the source of truth for the reproducible
  demo.
  """
  def materialize_cinnox_cc! do
    root = Path.dirname(kb_db_runtime_path())
    work = cc_slow_work_dir()

    File.mkdir_p!(root)
    File.mkdir_p!(work)
    File.mkdir_p!(Path.join(work, "plugins"))

    copy_tree!(Path.join(CinnoxAssets.root(), "flow_chunks"), Path.join(work, "plugins/cinnox/flow_chunks"))
    copy_tree!(Path.join(CinnoxAssets.root(), "references"), Path.join(work, "plugins/cinnox/references"))
    copy_tree!(Path.join(CinnoxAssets.root(), "skills"), Path.join(work, "plugins/cinnox/skills"))
    copy_tree!(Path.join(CinnoxAssets.root(), "skill-packages"), Path.join(work, "plugins/cinnox/skill-packages"))

    File.write!(Path.join(work, "CLAUDE.md"), CinnoxAssets.build_cc_claude_md())
    File.cp!(CinnoxAssets.kb_db_path(), kb_db_runtime_path())
    File.cp!(CinnoxAssets.kb_mcp_script_path(), kb_mcp_script_runtime_path())
    File.cp!(CinnoxAssets.kb_query_expansion_path(), kb_query_expansion_runtime_path())

    write_kb_mcp_config!()
    work
  end

  defp write_kb_mcp_config! do
    body = %{
      "mcpServers" => %{
        "cinnox-kb" => %{
          "command" => "uv",
          "args" => ["run", "--script", kb_mcp_script_runtime_path()],
          "env" => %{"KB_DB_PATH" => kb_db_runtime_path()}
        }
      }
    }

    File.write!(kb_mcp_config_runtime_path(), Jason.encode_to_iodata!(body, pretty: true))
  end

  defp copy_tree!(src, dst) do
    File.rm_rf!(dst)
    File.mkdir_p!(Path.dirname(dst))
    {:ok, _} = File.cp_r(src, dst)
  end
end
