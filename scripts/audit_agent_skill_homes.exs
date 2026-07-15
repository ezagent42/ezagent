# 盘点 agent config home 的 skill 物化状态(只读,不写任何文件/DB)。
#
# 配套方案:docs/notes/2026-07-15-agent-skill-loading-repair-plan.zh_cn.md(R0)。
# 输出每个 durable agent 的分类:
#   ok / missing / outdated / no_expected_skills / no_home / no_config_dir
# 以及无快照认领的 orphan home 列表 —— 用来决定 R2 sweep 的范围。
#
# 用法:
#   dev(全量 boot,期望值查当前 RecipeRegistry):
#           mix run scripts/audit_agent_skill_homes.exs
#   dev(轻量,只起 ezagent_core;boot 失败时的兜底,如缺 cap signing seed):
#           mix run --no-start scripts/audit_agent_skill_homes.exs
#   canary: 在 running node 的 remote console 里
#           Code.eval_file("scripts/audit_agent_skill_homes.exs")
#
# 依赖:kind_snapshots 可读;RecipeRegistry / SkillRegistry 若未 ready 则自动降级
# (期望 refs 回退到快照里的 sandbox_content.skills;hash 对比跳过,只查存在性)。
# 输出头部会自报保真度(fidelity)—— degraded 模式下 no_expected_skills 可能偏多,
# 正式盘点(canary)请在全量 booted 的节点上跑。

defmodule Ezagent.Scripts.AuditAgentSkillHomes do
  @headless_flavors ["cc-headless", "cc-headless-deepseek"]

  def run do
    ensure_started!()

    reports =
      Ezagent.Ecto.KindSnapshot.list_all()
      |> Enum.filter(&agent_uri?(&1.uri))
      |> Enum.map(&audit_row/1)

    print_report(reports)
    print_orphans(reports)
    :ok
  end

  defp ensure_started! do
    unless Process.whereis(Ezagent.Repo) do
      {:ok, _} = Application.ensure_all_started(:ezagent_core)
    end
  end

  defp agent_uri?(uri) when is_binary(uri), do: String.contains?(uri, "/agent/")
  defp agent_uri?(_), do: false

  # ── per-agent audit ────────────────────────────────────────────────────────

  defp audit_row(row) do
    sandbox = row |> decode_state() |> find_sandbox()
    respawn = get_any(sandbox || %{}, [:respawn_template_data, "respawn_template_data"]) || %{}

    config_dir =
      get_any(respawn, ["agent_config_dir", :agent_config_dir]) ||
        get_any(sandbox || %{}, [:config_dir_path, "config_dir_path"])

    flavor = get_any(respawn, ["flavor", :flavor])
    role = get_any(respawn, ["role", :role])
    expected = expected_refs(role, declared_refs(respawn))

    base = %{
      uri: row.uri,
      flavor: flavor,
      role: role,
      config_dir: config_dir,
      headless?: flavor in @headless_flavors,
      expected: expected,
      missing: [],
      outdated: [],
      unresolvable: []
    }

    cond do
      expected == [] -> Map.put(base, :status, :no_expected_skills)
      not is_binary(config_dir) -> Map.put(base, :status, :no_config_dir)
      not File.dir?(config_dir) -> Map.put(base, :status, :no_home)
      true -> base |> Map.merge(check_refs(config_dir, expected)) |> classify()
    end
  end

  defp classify(%{missing: [], outdated: []} = r), do: Map.put(r, :status, :ok)
  defp classify(%{missing: [_ | _]} = r), do: Map.put(r, :status, :missing)
  defp classify(r), do: Map.put(r, :status, :outdated)

  defp check_refs(config_dir, expected) do
    Enum.reduce(expected, %{missing: [], outdated: [], unresolvable: []}, fn ref, acc ->
      dir = Path.join([config_dir, "skills", ref])

      cond do
        not File.dir?(dir) -> Map.update!(acc, :missing, &[ref | &1])
        stale?(ref, dir) -> Map.update!(acc, :outdated, &[ref | &1])
        resolvable?(ref) -> acc
        true -> Map.update!(acc, :unresolvable, &[ref | &1])
      end
    end)
    |> Map.new(fn {k, v} -> {k, Enum.reverse(v)} end)
  end

  # Hash-compare against the current seed; degrade to presence-only when the
  # SkillRegistry isn't ready (e.g. a node that never booted ezagent_web).
  defp stale?(ref, copied_dir) do
    with true <- registry_ready?(),
         {:ok, {_source_dir, seed_hash}} <- safe_resolve(ref) do
      safe_dir_hash(copied_dir) != seed_hash
    else
      _ -> false
    end
  end

  defp resolvable?(ref) do
    case registry_ready?() and safe_resolve(ref) do
      {:ok, _} -> true
      # registry not booted → can't judge, don't flag
      false -> true
      _ -> false
    end
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
    Ezagent.SkillRegistry.dir_hash(dir)
  rescue
    _ -> nil
  end

  # ── expected refs: current recipe first, snapshot-declared as fallback ─────

  defp expected_refs(role, declared) do
    (recipe_refs(role) || declared || [])
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp recipe_refs(role) when is_binary(role) and role not in ["", "default"] do
    with true <- Code.ensure_loaded?(Ezagent.Agent.RecipeRegistry),
         {:ok, recipe} <- safe_lookup(role),
         refs when is_list(refs) <- Map.get(recipe, :skills) do
      refs
    else
      _ -> nil
    end
  end

  defp recipe_refs(_), do: nil

  defp safe_lookup(role) do
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

  # ── snapshot decoding (same tolerance as Home.Migration: decode w/o :safe,
  #    skip undecodable rows rather than crash) ────────────────────────────────

  defp decode_state(%{state_binary: bin}) when is_binary(bin) do
    :erlang.binary_to_term(bin)
  rescue
    _ -> nil
  end

  defp decode_state(%{state: %{} = state}), do: state
  defp decode_state(_), do: nil

  # Deep-walk arbitrary terms for the first map carrying the Sandbox slice keys.
  defp find_sandbox(%{} = m) do
    keys = [:respawn_template_data, "respawn_template_data", :config_dir_path, "config_dir_path"]

    if Enum.any?(keys, &Map.has_key?(m, &1)) do
      m
    else
      m |> Map.values() |> find_sandbox()
    end
  end

  defp find_sandbox(list) when is_list(list), do: Enum.find_value(list, &find_sandbox/1)
  defp find_sandbox(t) when is_tuple(t), do: t |> Tuple.to_list() |> find_sandbox()
  defp find_sandbox(_), do: nil

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

    for status <- [:missing, :outdated, :no_home, :no_config_dir, :ok, :no_expected_skills] do
      IO.puts("  #{String.pad_trailing(to_string(status), 20)} #{Map.get(counts, status, 0)}")
    end

    problems =
      Enum.filter(reports, &(&1.status in [:missing, :outdated, :no_home, :no_config_dir]))

    if problems != [] do
      IO.puts("\n-- needs attention " <> String.duplicate("-", 60))

      Enum.each(problems, fn r ->
        headless = if r.headless?, do: " [headless: R1 未落地前刷了也读不到]", else: ""

        IO.puts("""
        #{r.status}  #{r.uri}
          flavor=#{r.flavor || "?"} role=#{r.role || "?"} home=#{r.config_dir || "-"}#{headless}
          expected=#{inspect(r.expected)} missing=#{inspect(r.missing)} outdated=#{inspect(r.outdated)}\
        #{if r.unresolvable != [], do: " unresolvable=#{inspect(r.unresolvable)}", else: ""}
        """)
      end)
    else
      IO.puts("\n(no stale homes — R2 sweep 无存量目标)")
    end
  end

  # Homes on disk that no snapshot claims — informational only.
  defp print_orphans(reports) do
    claimed =
      reports
      |> Enum.map(& &1.config_dir)
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&Path.expand/1)
      |> MapSet.new()

    orphans =
      Ezagent.Home.profile_dir()
      |> Path.join("*-agents/*/*")
      |> Path.wildcard()
      |> Enum.filter(&File.dir?/1)
      |> Enum.reject(&MapSet.member?(claimed, Path.expand(&1)))

    IO.puts("-- orphan homes (on disk, no snapshot claims them): #{length(orphans)}")
    orphans |> Enum.take(20) |> Enum.each(&IO.puts("  #{&1}"))
    if length(orphans) > 20, do: IO.puts("  … (#{length(orphans) - 20} more)")
    IO.puts("")
  end
end

Ezagent.Scripts.AuditAgentSkillHomes.run()
