# 盘点 agent config home 的 skill 物化状态。
#
# 配套方案:docs/notes/2026-07-15-agent-skill-loading-repair-plan.zh_cn.md(R0)。
#
# 契约(codex review #1418 后收紧):
#   - 本脚本自身**不启动任何应用**:Ezagent.Repo 未运行时直接报错退出,
#     不调用 Application.ensure_all_started(启动 ezagent_core 会带出
#     Migrator / system Kind spawn / audit writer 等写路径)。
#   - 显式 IO 全为读:KindSnapshot.list_all + File.dir?/exists?/Path.wildcard +
#     SkillRegistry.resolve/dir_hash + RecipeRegistry.lookup(read-through,
#     命中缺失时会写 registry 的进程内 ETS 缓存 —— 运行时缓存,非持久状态)。
#
# 用法:
#   dev:    EZAGENT_SIGNING_SEED_V1=<≥32字节> mix run scripts/audit_agent_skill_homes.exs
#           (boot 由 mix run 负责;boot 副作用是环境行为,不是本脚本行为)
#   canary: 在 running node 的 remote console 里
#           Code.eval_file("scripts/audit_agent_skill_homes.exs")
#
# 每个 durable agent(kind_snapshots.kind_type == "agent")输出一个状态:
#   decode_error       snapshot 解码失败 —— 证据不足,单列,不并入其他类
#   no_sandbox_slice   无 :sandbox slice(native 等无 config-home flavor,正常)
#   no_config_dir      有 sandbox 但取不到 config_dir
#   no_home            config_dir 不存在于磁盘
#   unmarked_home      home 在但无 .ezagent-config-complete marker(半物化/手建)
#   no_expected_skills 期望 skill refs 为空(recipe 不带 skill)
#   missing            期望 ref 在 home 里缺失
#   outdated           ref 在但内容 hash 与当前 seed 不一致
#   hash_error         hash 计算异常(权限/竞态)—— unknown,不当 outdated
#   unresolvable       home 里有该 ref 但当前 seed/registry 已无此 ref
#   ok                 期望 refs 齐且 hash 与当前 seed 一致
# 期望 refs:RecipeRegistry.lookup(workspace, role)(tenant-aware),降级回退
# 快照里的 sandbox_content.skills;SkillRegistry 未 ready 时只查存在性。
# 输出头部自报保真度;orphan 判定同时用 config_dir 与 URI 推导的 <ws>/<name>
# 认领,decode 失败的 agent 不会把自己的 home 误报成 orphan。

defmodule Ezagent.Scripts.AuditAgentSkillHomes do
  @headless_flavors ["cc-headless", "cc-headless-deepseek"]

  @attention [
    :missing,
    :outdated,
    :hash_error,
    :unresolvable,
    :unmarked_home,
    :no_home,
    :no_config_dir,
    :decode_error
  ]

  @all_statuses @attention ++ [:ok, :no_expected_skills, :no_sandbox_slice]

  def run do
    ensure_repo!()

    rows =
      Ezagent.Ecto.KindSnapshot.list_all()
      |> Enum.filter(&agent_row?/1)

    reports = Enum.map(rows, &audit_row/1)
    print_report(reports)
    print_orphans(rows, reports)
    :ok
  end

  defp ensure_repo! do
    unless Process.whereis(EzagentCore.Repo) do
      raise """
      Ezagent.Repo 未启动 —— 本脚本不启动任何应用(零启动零写契约,见文件头)。
      dev:    EZAGENT_SIGNING_SEED_V1=<≥32字节> mix run scripts/audit_agent_skill_homes.exs
      canary: 在 running node 的 remote console 里 Code.eval_file 本文件
      """
    end
  end

  # kind_type 是权威过滤(Entity.Agent.type_name == :agent);nil kind_type 的
  # 遗留行退回 entity URI 结构判断。
  defp agent_row?(%{kind_type: "agent"}), do: true

  defp agent_row?(%{kind_type: nil, uri: uri}) when is_binary(uri),
    do: String.starts_with?(uri, "entity://") and String.contains?(uri, "/agent/")

  defp agent_row?(_), do: false

  # ── per-agent audit ────────────────────────────────────────────────────────

  defp audit_row(row) do
    base = %{
      uri: row.uri,
      workspace_uri: row.workspace_uri,
      flavor: nil,
      role: nil,
      config_dir: nil,
      headless?: false,
      marker?: nil,
      expected: [],
      missing: [],
      outdated: [],
      hash_errors: [],
      unresolvable: []
    }

    case Ezagent.Ecto.KindSnapshot.decode_state(row) do
      {:ok, state} -> audit_state(base, state)
      _ -> Map.put(base, :status, :decode_error)
    end
  end

  defp audit_state(base, state) do
    case get_any(state, [:sandbox, "sandbox"]) do
      %{} = slice -> audit_sandbox(base, unwrap_slice(slice))
      _ -> Map.put(base, :status, :no_sandbox_slice)
    end
  end

  # Lifecycle 快照里 slice 是 %{state: <durable 字段>} 包装(codex #1418 Medium);
  # 兼容无包装的旧形状。
  defp unwrap_slice(slice) do
    case get_any(slice, [:state, "state"]) do
      %{} = inner -> inner
      _ -> slice
    end
  end

  defp audit_sandbox(base, sandbox) do
    respawn = get_any(sandbox, [:respawn_template_data, "respawn_template_data"]) || %{}

    config_dir =
      get_any(respawn, ["agent_config_dir", :agent_config_dir]) ||
        get_any(sandbox, [:config_dir_path, "config_dir_path"])

    flavor = get_any(respawn, ["flavor", :flavor])
    role = get_any(respawn, ["role", :role])
    expected = expected_refs(base.workspace_uri, role, declared_refs(respawn))

    base = %{
      base
      | flavor: flavor,
        role: role,
        config_dir: config_dir,
        headless?: flavor in @headless_flavors,
        expected: expected
    }

    # codex #1418 Medium 的掩盖问题靠 decode_error 单列 + fidelity 自报解决;
    # expected == [] 表示"无可审计对象"(py/native/curl 等无 skill flavor 合法
    # 落在这里),之后才对携带期望的 agent 做 home 状态硬检查。
    cond do
      expected == [] ->
        Map.put(base, :status, :no_expected_skills)

      not (is_binary(config_dir) and config_dir != "") ->
        Map.put(base, :status, :no_config_dir)

      not File.dir?(config_dir) ->
        Map.put(base, :status, :no_home)

      not marker?(config_dir) ->
        base |> Map.put(:marker?, false) |> Map.put(:status, :unmarked_home)

      true ->
        base
        |> Map.put(:marker?, true)
        |> Map.merge(check_refs(config_dir, expected))
        |> classify()
    end
  end

  defp classify(r) do
    cond do
      r.missing != [] -> Map.put(r, :status, :missing)
      r.outdated != [] -> Map.put(r, :status, :outdated)
      r.hash_errors != [] -> Map.put(r, :status, :hash_error)
      r.unresolvable != [] -> Map.put(r, :status, :unresolvable)
      true -> Map.put(r, :status, :ok)
    end
  end

  defp check_refs(config_dir, expected) do
    acc = %{missing: [], outdated: [], hash_errors: [], unresolvable: []}

    expected
    |> Enum.reduce(acc, fn ref, acc ->
      dir = Path.join([config_dir, "skills", ref])

      cond do
        not File.dir?(dir) ->
          Map.update!(acc, :missing, &[ref | &1])

        not registry_ready?() ->
          # registry 未 boot:降级为存在性检查,不下 hash/解析结论
          acc

        true ->
          case safe_resolve(ref) do
            {:ok, {_source_dir, seed_hash}} -> compare_hash(acc, ref, dir, seed_hash)
            _ -> Map.update!(acc, :unresolvable, &[ref | &1])
          end
      end
    end)
    |> Map.new(fn {k, v} -> {k, Enum.reverse(v)} end)
  end

  defp compare_hash(acc, ref, dir, seed_hash) do
    case safe_dir_hash(dir) do
      {:ok, ^seed_hash} -> acc
      {:ok, _other} -> Map.update!(acc, :outdated, &[ref | &1])
      :error -> Map.update!(acc, :hash_errors, &[ref | &1])
    end
  end

  defp marker?(config_dir) do
    File.exists?(Path.join(config_dir, marker_name()))
  end

  defp marker_name do
    Ezagent.Credential.HomeRuntime.config_complete_marker()
  rescue
    _ -> ".ezagent-config-complete"
  end

  defp registry_ready? do
    Code.ensure_loaded?(Ezagent.SkillRegistry) and Ezagent.SkillRegistry.ready?()
  rescue
    _ -> false
  end

  defp safe_resolve(ref) do
    Ezagent.SkillRegistry.resolve(ref)
  rescue
    _ -> {:error, :registry_unavailable}
  end

  defp safe_dir_hash(dir) do
    {:ok, Ezagent.SkillRegistry.dir_hash(dir)}
  rescue
    _ -> :error
  end

  # ── expected refs: tenant-aware recipe first, snapshot-declared fallback ───

  defp expected_refs(workspace_uri, role, declared) do
    (recipe_refs(workspace_uri, role) || declared || [])
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp recipe_refs(workspace_uri, role) when is_binary(role) and role not in ["", "default"] do
    with true <- Code.ensure_loaded?(Ezagent.Agent.RecipeRegistry),
         {:ok, recipe} <- safe_lookup(workspace_uri, role),
         refs when is_list(refs) <- Map.get(recipe, :skills) do
      refs
    else
      _ -> nil
    end
  end

  defp recipe_refs(_, _), do: nil

  # lookup/2 是 tenant-aware API(lookup/1 只查 system workspace,codex #1418 High)
  defp safe_lookup(ws, role) when is_binary(ws) and ws != "" do
    Ezagent.Agent.RecipeRegistry.lookup(ws, role)
  rescue
    _ -> :error
  end

  defp safe_lookup(_, role) do
    Ezagent.Agent.RecipeRegistry.lookup(role)
  rescue
    _ -> :error
  end

  defp declared_refs(respawn) do
    case get_any(respawn, ["sandbox_content", :sandbox_content]) do
      %{} = sc -> get_any(sc, [:skills, "skills"])
      _ -> nil
    end
  end

  defp get_any(%{} = m, keys), do: Enum.find_value(keys, &Map.get(m, &1))
  defp get_any(_, _), do: nil

  # ── output ──────────────────────────────────────────────────────────────────

  defp recipe_registry_live? do
    if Code.ensure_loaded?(Ezagent.Agent.RecipeRegistry) do
      _ = Ezagent.Agent.RecipeRegistry.lookup("__audit_probe__")
      true
    else
      false
    end
  rescue
    _ -> false
  end

  defp print_report(reports) do
    counts = Enum.frequencies_by(reports, & &1.status)

    fidelity =
      "recipe_registry=#{if recipe_registry_live?(), do: "live", else: "DEGRADED(快照回退)"} " <>
        "skill_registry=#{if registry_ready?(), do: "ready", else: "DEGRADED(只查存在性)"}"

    IO.puts("\n== agent skill home audit (#{length(reports)} durable agents) ==")
    IO.puts("   fidelity: #{fidelity}\n")

    for status <- @all_statuses do
      IO.puts("  #{String.pad_trailing(to_string(status), 20)} #{Map.get(counts, status, 0)}")
    end

    problems = Enum.filter(reports, &(&1.status in @attention))

    if problems != [] do
      IO.puts("\n-- needs attention " <> String.duplicate("-", 60))

      Enum.each(problems, fn r ->
        headless = if r.headless?, do: " [headless: R1 未落地前刷了也读不到]", else: ""

        IO.puts("""
        #{r.status}  #{r.uri}
          flavor=#{r.flavor || "?"} role=#{r.role || "?"} marker=#{inspect(r.marker?)} home=#{r.config_dir || "-"}#{headless}
          expected=#{inspect(r.expected)} missing=#{inspect(r.missing)} outdated=#{inspect(r.outdated)}\
        #{if r.hash_errors != [], do: " hash_errors=#{inspect(r.hash_errors)}", else: ""}\
        #{if r.unresolvable != [], do: " unresolvable=#{inspect(r.unresolvable)}", else: ""}
        """)
      end)
    else
      IO.puts("\n(no stale homes — R2 sweep 无存量目标)")
    end
  end

  # orphan = 磁盘上的 <ns>-agents/<ws>/<name> 目录,既不被任何 report 的
  # config_dir 认领,也不匹配任何 agent snapshot URI 推导的 {ws, name}
  # (后者兜住 decode_error 行,避免把真实 agent 的 home 误报成 orphan)。
  defp print_orphans(rows, reports) do
    claimed_dirs =
      reports
      |> Enum.map(& &1.config_dir)
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&Path.expand/1)
      |> MapSet.new()

    claimed_ws_names =
      rows
      |> Enum.map(&uri_ws_name/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    orphans =
      Ezagent.Home.profile_dir()
      |> Path.join("*-agents/*/*")
      |> Path.wildcard()
      |> Enum.filter(&File.dir?/1)
      |> Enum.reject(fn path ->
        MapSet.member?(claimed_dirs, Path.expand(path)) or
          MapSet.member?(claimed_ws_names, tail_ws_name(path))
      end)

    IO.puts("-- orphan homes (on disk, no snapshot claims them): #{length(orphans)}")
    orphans |> Enum.take(20) |> Enum.each(&IO.puts("  #{&1}"))
    if length(orphans) > 20, do: IO.puts("  … (#{length(orphans) - 20} more)")
    IO.puts("")
  end

  defp uri_ws_name(%{uri: uri}) when is_binary(uri) do
    u = Ezagent.URI.new!(uri)
    {Ezagent.URI.workspace_name!(u), Ezagent.URI.name!(u)}
  rescue
    _ -> nil
  end

  defp uri_ws_name(_), do: nil

  defp tail_ws_name(path) do
    case path |> Path.split() |> Enum.take(-2) do
      [ws, name] -> {ws, name}
      _ -> nil
    end
  end
end

Ezagent.Scripts.AuditAgentSkillHomes.run()
