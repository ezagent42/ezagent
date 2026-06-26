defmodule EzagentPluginKanban.Ci do
  @moduledoc """
  CI 评价（片5，纯函数读模型）。

  给一个 `stage==:pr` 的节点，沿**祖先链**（固定接力链：…→feature→issue→test→pr）算几条判据——
  上游各棒是否 `done`、feature 是否有 Gherkin 验收、是否挂了 issue、test 是否绿——出评分 + markdown 评语。

  **纯读、无副作用、不新增 dispatch action**（不碰 boot 期注册/不用重启）。供 `read_tree` 给 pr 节点附
  `ci` 摘要（前端 ci 徽章），以及片6 `GithubSync` 出 PR 评论用。CI 评价逻辑本就是 ezagent 领域逻辑、
  数据都在真相源，所以放 kanban 插件内、纯出站消费。
  """

  @type verdict :: %{
          score: non_neg_integer(),
          max: non_neg_integer(),
          criteria: [%{key: atom(), name: String.t(), ok: boolean()}],
          markdown: String.t()
        }

  @doc "对一个 pr 节点算 CI 评价（tree 用内部 atom-key 结构 `%{nodes: %{}, ...}`）。"
  @spec check_pr_gate(map(), String.t()) :: verdict()
  def check_pr_gate(%{nodes: nodes}, pr_id) when is_map_key(nodes, pr_id) do
    chain = ancestor_chain(nodes, pr_id)
    feature = Enum.find(chain, &(stage(&1) == :feature))
    issue = Enum.find(chain, &(stage(&1) == :issue))
    test = Enum.find(chain, &(stage(&1) == :test))

    criteria = [
      crit(
        :upstream_done,
        "上游各棒已 done",
        Enum.all?(chain, &(stage(&1) == :pr or status(&1) == :done))
      ),
      crit(:gherkin, "feature 有 Gherkin 验收", feature && has_gherkin?(feature)),
      crit(:issue, "挂了 issue 产物", issue && has_kind?(issue, "issue")),
      crit(:test_green, "test 套件绿", test && test_green?(test))
    ]

    passed = Enum.count(criteria, & &1.ok)

    %{
      score: passed,
      max: length(criteria),
      criteria: criteria,
      markdown: to_markdown(criteria, passed)
    }
  end

  def check_pr_gate(_tree, _id), do: %{score: 0, max: 0, criteria: [], markdown: ""}

  @doc """
  verdict → GitHub commit status state（硬 CI 门，B2）。

  全部判据通过=`success`（绿，放行）；有判据未过=`failure`（红，挡合并）；
  无判据（节点还没到 pr 棒 / 未知节点）=`pending`（中性，不挡）。
  供 `Connectors.push_pr` 推 `create_commit_status` 用。
  """
  @spec gate_state(verdict()) :: String.t()
  def gate_state(%{max: 0}), do: "pending"
  def gate_state(%{score: s, max: m}) when s == m, do: "success"
  def gate_state(%{score: _, max: _}), do: "failure"

  @stage_labels %{
    positioning: "定位",
    metric: "北极星",
    pain: "痛点",
    anchor: "认领映射",
    ux: "线框",
    feature: "功能卡",
    issue: "issue",
    test: "测试",
    pr: "PR"
  }

  @doc """
  产品需求摘要（出站到 PR 的留言）：沿 PR 节点的**祖先链**（定位→…→feature→…→pr）把每一棒
  已有的文档（节点 content 产物）+ 指标拼成"本 PR 要满足的产品需求"。

  **确定性汇总**（不是 LLM 综合，也不拉 GitHub 原始数据）——真相源在 ezagent，留言把产品上下文
  带给 PR 评审。LLM 智能总结是 path B（要 kanban agent，归 Allen）。
  """
  @spec requirement_digest(map(), String.t()) :: String.t()
  def requirement_digest(%{nodes: nodes}, node_id) when is_map_key(nodes, node_id) do
    sections =
      nodes
      |> ancestor_chain(node_id)
      |> Enum.map(&digest_section/1)

    "## 本 PR 的产品上下文（ezagent 自动汇总）\n\n" <>
      Enum.join(sections, "\n\n") <> "\n\n———\n请确保实现满足以上产品需求。"
  end

  def requirement_digest(_tree, _id), do: ""

  defp digest_section(n) do
    label = Map.get(@stage_labels, stage(n), to_string(stage(n)))

    docs =
      arts(n)
      |> Enum.map(&content/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    metrics =
      n
      |> Map.get(:metrics, [])
      |> Enum.map(fn m -> "- 指标 #{afield(m, :name)}：目标 #{afield(m, :target)}" end)
      |> Enum.join("\n")

    ["### [#{label}] #{Map.get(n, :title)}", docs, metrics]
    |> Enum.reject(&(&1 == "" or is_nil(&1)))
    |> Enum.join("\n")
  end

  # --- helpers（纯函数）---------------------------------------------------

  defp ancestor_chain(nodes, id, acc \\ []) do
    case Map.get(nodes, id) do
      nil -> acc
      n -> ancestor_chain(nodes, Map.get(n, :parent_id), [n | acc])
    end
  end

  defp stage(n), do: Map.get(n, :stage)
  defp status(n), do: Map.get(n, :status)
  defp arts(n), do: Map.get(n, :artifacts, [])

  defp crit(key, name, ok), do: %{key: key, name: name, ok: !!ok}

  defp has_gherkin?(n),
    do: Enum.any?(arts(n), fn a -> String.match?(content(a), ~r/given|when|then|当|则|如果/i) end)

  defp has_kind?(n, k), do: Enum.any?(arts(n), fn a -> to_string(afield(a, :kind)) == k end)

  defp test_green?(n) do
    Enum.any?(arts(n), fn a ->
      to_string(afield(a, :kind)) == "test_suite" and to_string(afield(a, :ref)) == "green"
    end)
  end

  defp content(a), do: to_string(afield(a, :content) || "")
  defp afield(a, k) when is_map(a), do: Map.get(a, k) || Map.get(a, to_string(k))

  defp to_markdown(criteria, passed) do
    lines = Enum.map(criteria, fn c -> "- [#{if c.ok, do: "x", else: " "}] #{c.name}" end)
    "## ezagent CI gate（#{passed}/#{length(criteria)}）\n" <> Enum.join(lines, "\n")
  end
end
