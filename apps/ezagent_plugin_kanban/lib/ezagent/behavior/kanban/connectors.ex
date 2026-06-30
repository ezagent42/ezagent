defmodule Ezagent.Behavior.Kanban.Connectors do
  @moduledoc """
  Kanban Behavior 的**出站连接器动作实现体**（df-tech 下沉：原在 world kanban_actions.ex，
  先搬进 `Ezagent.Behavior.Kanban` 收口，再从该 Behavior 主模块拆出实现体到本模块——
  主模块只留 `action/3` 宏声明 + `def handle_<x>(a,c), do: Connectors.<x>(a,c)` 薄转发，
  契约/宏不变，仅把实现体搬来此处压主模块 LOC）。

  这组动作：`sync_github` / `push_pr` / `register_pr` / `attach_code_file` / `sync_prs` /
  `sync_miro` / `set_board_config` / `save_github_creds` / `save_miro_creds`。

  ## 授权 + effect 契约（与主模块一致，未变）
  - 节点级动作（sync_github/push_pr/register_pr/attach_code_file）沿用 `Shared.owner_or_admin?/2`
    闸——同 attach_artifact 要节点 owner 或 admin。
  - 图级动作（sync_prs/sync_miro/set_board_config）= 任意持 cap 的成员（cap gate 已收口）。
  - 凭证保存（save_*_creds）= admin-gated（全局配置）。
  - 出站副作用在 Kind 进程内同步调（拿结果决定是否 commit + 拼回返回值，纯 `{:ref}`
    替换表达不了这层逻辑，对齐 UserTokens handler 内联 Token.list 先例）；只有真改树
    （挂 artifact / set done）才经 `Shared.commit/1`——**树写入仍是全 Behavior 唯一的
    `tree set-effect（经 commit/1 收口）` 收口点**。

  ## GitHub 出站 = dispatch github gateway（Phase 2：github 抽成独立插件）

  原 `EzagentPluginKanban.Github`（httpc client）已删。GitHub 能力下沉到独立的
  `ezagent_plugin_github` 插件，以 `Ezagent.Behavior.Github` 挂在系统单例 gateway agent
  （`entity://system/agent/github_gateway`）上。kanban **经 `gh/3` dispatch** 调它
  （`Ezagent.Invocation.dispatch/1`，仿 `MiroSync.do_dispatch` 范式，系统身份），跨插件
  零直调（守不变式 #8）。token 读写全归 github 插件 `Creds`：kanban 不再读/写
  `github.yaml`，repo 取本图 `BoardConfig`、随动作参数传给 gateway；凭证保存经
  `gh(:save_creds, …)` 收口在 github 插件。
  """

  require Logger

  alias Ezagent.Behavior.Kanban.Shared
  alias Ezagent.Routing.{Resolver, RuleStore}
  alias EzagentPluginKanban.BoardConfig
  alias EzagentPluginKanban.Ci
  alias EzagentPluginKanban.Miro
  alias EzagentPluginKanban.MiroSync
  alias EzagentPluginKanban.PmCoordinatorSeed
  alias EzagentPluginKanban.RelayRouting

  # T7d — the GENERIC by-role materialize (domain_agent). Used to materialize the
  # `dev-together` role, whose role-as-data lives in `Ezagent.Agent.DefaultRecipes`
  # and is boot-seeded by `Ezagent.Agent.DefaultRecipeSeed` (agent domain):
  # reaching it by role NAME via the registry + the shared engine keeps ZERO
  # compile dep on its definition (the same plugin→domain discipline as the
  # github gateway).
  alias Ezagent.Agent.SessionAgentMaterialize

  # Mix.env() resolved at compile time (works in stripped releases) — gates the
  # T7c per-session pm materialize so the heavy `cc` sidecar spawn never runs in
  # `:test` (the spawn MECHANISM is proven by SessionAgentMaterializeTest; the
  # `:triggered` telemetry still fires so the wiring is observable in test).
  @compile_env Mix.env()

  # T7c per-session pm materialize telemetry root.
  @pm_materialize_telemetry [:ezagent, :kanban, :pm_coordinator_seed, :materialize]

  # T7d per-session dev-together materialize telemetry root + role name.
  @dev_together_role "dev-together"
  @dev_together_materialize_telemetry [:ezagent, :kanban, :dev_together, :materialize]

  # T12 relay-BACK (dev→pm 自动接力 = 一条 sender-locked 路由规则) telemetry root +
  # the per-session rule-set name used as the reconcile identity (with created_by =
  # session_uri, position 0) so a re-bind of the SAME session reconciles instead of
  # accumulating duplicate rows (team-routing §3.7 materialization-reconcile 范式).
  @relay_back_telemetry [:ezagent, :kanban, :relay_back, :materialize]
  @relay_back_rule_set "kanban_relay_back"

  # 出站到 GitHub：建 issue + 回挂 issue 产物到节点（同节点 = 折进一次 commit，不自分发）。
  @doc false
  def sync_github(%{id: id}, ctx) do
    t = Shared.tree(ctx)

    cond do
      not Map.has_key?(t.nodes, id) ->
        {:error, :node_not_found}

      not Shared.owner_or_admin?(ctx, t.nodes[id]) ->
        {:error, :forbidden}

      true ->
        case board_repo(ctx) do
          {:ok, repo} ->
            n = t.nodes[id]

            case gh(
                   :create_issue,
                   %{repo: repo, title: n.title || "(untitled)", body: github_issue_body(n)},
                   ctx
                 ) do
              {:ok, %{number: num, url: url}} ->
                art =
                  Shared.normalize_artifact(%{
                    tool: "github",
                    kind: "issue",
                    ref: "##{num}",
                    url: url
                  })

                new_nodes = Map.put(t.nodes, id, %{n | artifacts: n.artifacts ++ [art]})
                {:ok, %{number: num, url: url}, [Shared.commit(%{t | nodes: new_nodes})]}

              {:error, reason} ->
                {:error, gh_reason(reason)}
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # 出站 PR 留言（软留言）：把产品需求摘要（requirement_digest）post 到已登记 PR。
  # 纯出站、不改树。（B2 硬 CI 门——把 verdict 推成 commit status——已丢弃；
  # `Ci.check_pr_gate` 仍供 get_tree 的 ci 徽章纯读用，与本动作无关。）
  @doc false
  def push_pr(%{id: id}, ctx) do
    t = Shared.tree(ctx)

    with node when is_map(node) <- Map.get(t.nodes, id),
         true <- Shared.owner_or_admin?(ctx, node) or :forbidden,
         {:ok, repo} <- board_repo(ctx),
         pr when is_integer(pr) <- node_pr(node),
         digest <- Ci.requirement_digest(t, id),
         {:ok, %{url: url}} <- gh(:post_comment, %{repo: repo, number: pr, body: digest}, ctx) do
      {:ok, %{url: url}, []}
    else
      nil -> {:error, :node_not_found}
      :forbidden -> {:error, :forbidden}
      {:error, :github_repo_missing} -> {:error, :github_repo_missing}
      {:error, reason} -> {:error, gh_reason(reason)}
      false -> {:error, :no_pr_registered}
      _ -> {:error, :no_pr_registered}
    end
  end

  # 登记 PR：把 PR 链接挂到节点（不发评论；出站留言在 push_pr）。
  @doc false
  def register_pr(%{id: id, pr: pr_in}, ctx) do
    t = Shared.tree(ctx)

    cond do
      not Map.has_key?(t.nodes, id) ->
        {:error, :node_not_found}

      not Shared.owner_or_admin?(ctx, t.nodes[id]) ->
        {:error, :forbidden}

      true ->
        case {to_pr_number(pr_in), board_repo(ctx)} do
          {pr, {:ok, repo}} when is_integer(pr) and is_binary(repo) ->
            register_pr_artifact(t, id, repo, pr)

          {:error, _} ->
            {:error, :bad_pr_number}

          {_, {:error, reason}} ->
            {:error, reason}
        end
    end
  end

  # 把 PR 链接挂到节点——**自幂等**（守门员要的去重）：节点已有该 PR 号的 pr 产物则跳过，
  # 不重复 append（入站 poller 重投 / 节点重启清空 PrSync 的 ETS seen 后重放同一 open PR，
  # 都不再生成重复 artifact）。去重键 = (repo, node_id, pr)：repo 是本图锁定的仓库
  # （board_repo），node_id 是本节点，pr 经 `pr_already_registered?/2` 按节点现有 artifacts 判。
  defp register_pr_artifact(t, id, repo, pr) do
    n = t.nodes[id]

    if pr_already_registered?(n, pr) do
      {:ok, %{}, []}
    else
      url = "https://github.com/#{repo}/pull/#{pr}"
      art = Shared.normalize_artifact(%{tool: "github", kind: "pr", ref: "##{pr}", url: url})
      new_nodes = Map.put(t.nodes, id, %{n | artifacts: n.artifacts ++ [art]})
      {:ok, %{}, [Shared.commit(%{t | nodes: new_nodes})]}
    end
  end

  @doc """
  节点是否已登记过该 PR 号（`register_pr` 自幂等判断）：节点 artifacts 里已有一个
  `kind` 为 `"pr"` 且 `ref` 为 `"#<pr>"` 的产物则为真。

  Public 以便纯逻辑单测断言去重契约（按 (节点, pr号) 去重，不打真网 / 不起进程）。

      iex> alias Ezagent.Behavior.Kanban.Connectors
      iex> node = %{artifacts: [%{tool: "github", kind: "pr", ref: "#42"}]}
      iex> Connectors.pr_already_registered?(node, 42)
      true
      iex> Connectors.pr_already_registered?(node, 43)
      false
      iex> Connectors.pr_already_registered?(%{artifacts: []}, 42)
      false
  """
  @spec pr_already_registered?(map(), integer()) :: boolean()
  def pr_already_registered?(node, pr) when is_integer(pr) do
    ref = "#" <> Integer.to_string(pr)

    node
    |> Map.get(:artifacts, [])
    |> Enum.any?(fn a ->
      to_string(Map.get(a, :kind)) == "pr" and to_string(Map.get(a, :ref)) == ref
    end)
  end

  # 挂代码文件：钉 commit SHA + 路径 → 拼 github blob 链接（永久可点）。repo 取本图配置。
  @doc false
  def attach_code_file(%{id: id, sha: sha, path: path}, ctx)
      when is_binary(sha) and is_binary(path) do
    t = Shared.tree(ctx)

    cond do
      not Map.has_key?(t.nodes, id) ->
        {:error, :node_not_found}

      not Shared.owner_or_admin?(ctx, t.nodes[id]) ->
        {:error, :forbidden}

      true ->
        case board_repo(ctx) do
          {:ok, repo} ->
            clean = String.trim_leading(path, "/")
            url = "https://github.com/#{repo}/blob/#{sha}/#{clean}"
            name = clean |> String.split("/") |> List.last()

            art =
              Shared.normalize_artifact(%{
                tool: "github",
                kind: "github_file",
                ref: name,
                url: url
              })

            n = t.nodes[id]
            new_nodes = Map.put(t.nodes, id, %{n | artifacts: n.artifacts ++ [art]})
            {:ok, %{url: url}, [Shared.commit(%{t | nodes: new_nodes})]}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # 轮询已登记 PR 的节点；merged/closed → set_status done（折进一次 commit）。
  @doc false
  def sync_prs(_args, ctx) do
    t = Shared.tree(ctx)

    case board_repo(ctx) do
      {:ok, repo} ->
        {new_nodes, advanced, unreachable?} = advance_merged_prs(t.nodes, repo, ctx)

        cond do
          unreachable? -> {:error, :github_unreachable}
          advanced == 0 -> {:ok, %{advanced: 0}, []}
          true -> {:ok, %{advanced: advanced}, [Shared.commit(%{t | nodes: new_nodes})]}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # 一键推 Miro：已绑定则 sync；未绑定则建板+绑定+sync。板名取本图配置或默认。
  @doc false
  def sync_miro(_args, ctx) do
    uri = ctx[:self_uri]

    miro_name =
      case BoardConfig.read(uri).miro_board do
        name when is_binary(name) and name != "" -> name
        _ -> "ezagent: " <> uri_name(uri)
      end

    case MiroSync.sync_or_bind(uri, miro_name) do
      {:ok, %{board_id: board}} -> {:ok, %{board_id: board}, []}
      {:error, reason} -> {:error, reason}
    end
  end

  # 写本图连接器配置（github_repo + miro 板名）。任意持 cap 的成员（cap gate 收口）。
  # 配了 repo 后：若 session 已绑（repo+session 俱全）→ 起入站 poller；若 repo 被清且原本
  # 在跑 → 停（`reconcile_pr_sync/3`，session-gated 触发模型）。
  @doc false
  def set_board_config(%{github_repo: github_repo, miro_board: miro_board}, ctx) do
    uri = ctx[:self_uri]
    before = read_cfg(uri)

    case BoardConfig.write(uri, %{github_repo: github_repo, miro_board: miro_board}) do
      :ok ->
        c = BoardConfig.read(uri)
        reconcile_pr_sync(uri, before, ctx)
        {:ok, %{github_repo: c.github_repo, miro_board: c.miro_board}, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # 绑定本看板到一个会话（B1）：之后接力动作向该会话 session.send 公告、重入路由。
  # 任意持 cap 的成员（cap gate 收口）；合并写不动 github/miro 配置。绑 session 后：若
  # repo 已配（repo+session 俱全）→ 起入站 poller；若 session 被清且原本在跑 → 停
  # （`reconcile_pr_sync/3`——入站 poller 挂在"被绑 session"这根线上）。
  @doc false
  def bind_session(%{session_uri: session_uri}, ctx) do
    uri = ctx[:self_uri]
    before = read_cfg(uri)

    case BoardConfig.write(uri, %{session_uri: session_uri}) do
      :ok ->
        reconcile_pr_sync(uri, before, ctx)
        # T7c/T7d/T7g — binding a board to a session is the kanban-flow session
        # ESTABLISHMENT point: materialize the per-session role-agent brains
        # (best-effort, non-blocking — never fails the bind):
        #   * pm-coordinator (kanban's own default agent), and
        #   * dev-together (the system dev-block agent, a FOREIGN plugin reached
        #     generically by role name — T7d).
        # `uri` (= `ctx[:self_uri]`) is THIS board agent — T7g scopes pm's kanban
        # caps to it so pm can drive the board (the cap gates the board host, not pm).
        bound_session = BoardConfig.read(uri).session_uri
        trigger_session_agents_materialize(bound_session, uri, ctx)
        {:ok, %{session_uri: bound_session}, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # T7c/T7d/T7g — fire the per-session role-agent materializes when a kanban-flow
  # session is established (board→session bind). Best-effort + non-blocking:
  #   * a `cc` sidecar spawn is multi-second — running it inline would block the
  #     kanban-manager Kind's mailbox, so it runs DETACHED (`Task.start`);
  #   * a materialize failure must NEVER fail the operator's bind, so the result
  #     is surfaced via telemetry/Logger (cast-mode "who knows it failed"), not
  #     returned;
  #   * owner = `ctx[:caller]` (the entity binding the board) is a best-judgment
  #     for the credential-cascade owner — surfaced for Allen.
  #
  # Part B (T7g, act3 发现2 fix): pm + dev-together run SEQUENTIALLY inside ONE
  # detached Task. Two CONCURRENT `cc` cold starts raced the 20s activate budget +
  # DB pool (spawn rollback → the agent Kind died while its claude PTY looped
  # `REFUSED JOIN`). Serializing sidesteps the contention WITHOUT touching the
  # `activate_budget_ms` / pool defaults (Allen's budget decision). Both
  # `:triggered` events still fire UP-FRONT so the wiring stays observable in `:test`
  # (where the spawn itself is skipped — no live `claude`).
  #
  # `board_uri` (T7g Part A) is THIS board agent (`ctx[:self_uri]`): pm's kanban
  # caps are scoped to it so pm may drive the board.
  defp trigger_session_agents_materialize(session_uri, board_uri, ctx)
       when is_binary(session_uri) and session_uri != "" do
    with %URI{} = session <- safe_parse_uri(session_uri),
         %URI{} = workspace <- session_workspace(session),
         %URI{} = owner <- caller_uri(ctx),
         %URI{} = board <- normalize_board_uri(board_uri) do
      :telemetry.execute(@pm_materialize_telemetry ++ [:triggered], %{count: 1}, %{
        session_uri: session_uri
      })

      :telemetry.execute(@dev_together_materialize_telemetry ++ [:triggered], %{count: 1}, %{
        session_uri: session_uri
      })

      # T12 — the dev→pm relay-BACK routing rule (`from(dev) AND in_session → [pm]`).
      # Fired UP-FRONT (like the pm/dev `:triggered` events) so the wiring is observable
      # in `:test` even though the actual DB+ETS write is gated below.
      :telemetry.execute(@relay_back_telemetry ++ [:triggered], %{count: 1}, %{
        session_uri: session_uri
      })

      if @compile_env != :test do
        # The relay-BACK rule is DETERMINISTIC config (both agent URIs come from
        # `planned_agent_uri/3`, no live spawn) — wire it SYNCHRONOUSLY + best-effort,
        # independent of whether the cc sidecar spawns. It must exist as config even if
        # the live brain spawn fails. (Gated out of `:test` to avoid mutating the global
        # MentionRouting ETS table; the routing BEHAVIOR is proven by the isolated-table
        # `relay_back_routing_test.exs`, the same pattern `wire_relay_rule` uses.)
        wire_relay_back_routing(session, workspace)

        _ =
          Task.start(fn ->
            # SEQUENTIAL — pm first, THEN dev-together; never two concurrent cc cold starts.
            do_pm_materialize(session, workspace, owner, board)
            do_dev_together_materialize(session, workspace, owner)
          end)
      end

      :ok
    else
      _ -> :ok
    end
  end

  defp trigger_session_agents_materialize(_session_uri, _board_uri, _ctx), do: :ok

  defp normalize_board_uri(%URI{} = uri), do: uri
  defp normalize_board_uri(uri) when is_binary(uri) and uri != "", do: safe_parse_uri(uri)
  defp normalize_board_uri(_), do: :error

  defp do_pm_materialize(%URI{} = session, %URI{} = workspace, %URI{} = owner, %URI{} = board) do
    case PmCoordinatorSeed.materialize(session, workspace, owner, board) do
      {:ok, agent_uri, outcome} ->
        :telemetry.execute(@pm_materialize_telemetry ++ [:ok], %{count: 1}, %{
          agent_uri: URI.to_string(agent_uri),
          outcome: outcome
        })

      {:error, reason} ->
        Logger.warning(
          "kanban: pm-coordinator per-session materialize failed " <>
            "session=#{URI.to_string(session)} reason=#{inspect(reason)}"
        )

        :telemetry.execute(@pm_materialize_telemetry ++ [:failed], %{count: 1}, %{
          reason: inspect(reason)
        })
    end
  end

  defp do_dev_together_materialize(%URI{} = session, %URI{} = workspace, %URI{} = owner) do
    case SessionAgentMaterialize.materialize_by_role(
           @dev_together_role,
           session,
           workspace,
           owner
         ) do
      {:ok, agent_uri, outcome} ->
        :telemetry.execute(@dev_together_materialize_telemetry ++ [:ok], %{count: 1}, %{
          agent_uri: URI.to_string(agent_uri),
          outcome: outcome
        })

      {:error, reason} ->
        Logger.warning(
          "kanban: dev-together per-session materialize failed " <>
            "session=#{URI.to_string(session)} reason=#{inspect(reason)}"
        )

        :telemetry.execute(@dev_together_materialize_telemetry ++ [:failed], %{count: 1}, %{
          reason: inspect(reason)
        })
    end
  end

  # T12 — wire the dev→pm relay-BACK routing rule when the kanban-flow session is
  # established (board→session bind). Both endpoints are DERIVED deterministically from
  # the same `planned_agent_uri/3` the materializes use, so the rule can be wired WITHOUT
  # the live brains existing yet (a routing rule references URIs, it doesn't call them):
  #
  #   matcher  = from(dev-together-<sess>) AND in_session(<sess>)
  #   receiver = [pm-coordinator-<sess>]            (single — rule-set invariant holds)
  #
  # = the proven sender-locked relay primitive (core E2E Scenario 34 `{:from,X}→Y`),
  # scoped to THIS session. Because the matcher reads `message.sender` (transport-set,
  # NOT free-text), it fires on dev's return regardless of whether dev's `@pm` text
  # parsed into structured mentions (T11 surface F) — "不靠 @mention parse，靠路由规则".
  #
  # Idempotent: a re-bind of the SAME session reconciles via `find_by_identity` (created_by
  # = session_uri, rule_set = @relay_back_rule_set, position 0) instead of duplicating the
  # row (team-routing §3.7 materialization-reconcile 范式). Best-effort + non-blocking:
  # a wire failure NEVER fails the operator's bind — it surfaces via Logger/telemetry
  # ("who knows it failed" = cast-mode), same discipline as the materialize.
  defp wire_relay_back_routing(%URI{} = session, %URI{} = workspace) do
    table = Resolver.default_routing_table()

    pm_uri =
      SessionAgentMaterialize.planned_agent_uri(PmCoordinatorSeed.role_name(), session, workspace)

    dev_uri = SessionAgentMaterialize.planned_agent_uri(@dev_together_role, session, workspace)

    if RuleStore.find_by_identity(table, session, @relay_back_rule_set, 0) do
      :telemetry.execute(@relay_back_telemetry ++ [:already_wired], %{count: 1}, %{
        session_uri: URI.to_string(session)
      })
    else
      do_wire_relay_back(table, session, dev_uri, pm_uri)
    end
  rescue
    e ->
      Logger.warning("kanban: relay-back routing wire crashed: #{inspect(e)}")

      :telemetry.execute(@relay_back_telemetry ++ [:failed], %{count: 1}, %{reason: inspect(e)})
      :ok
  end

  defp do_wire_relay_back(table, %URI{} = session, %URI{} = dev_uri, %URI{} = pm_uri) do
    # created_by = session_uri is the §3.7 reconcile identity stamp (NOT the human owner) —
    # it keys `find_by_identity` so the SAME session's relay-back rule reconciles on re-bind.
    case RelayRouting.wire_relay_back_rule(table, session, dev_uri, pm_uri, session,
           rule_set: @relay_back_rule_set,
           position: 0
         ) do
      {:ok, _rule} ->
        RuleStore.load_into_registry(table)

        :telemetry.execute(@relay_back_telemetry ++ [:wired], %{count: 1}, %{
          session_uri: URI.to_string(session),
          from: URI.to_string(dev_uri),
          to: URI.to_string(pm_uri)
        })

      {:error, reason} ->
        Logger.warning(
          "kanban: relay-back wire failed " <>
            "session=#{URI.to_string(session)} reason=#{inspect(reason)}"
        )

        :telemetry.execute(@relay_back_telemetry ++ [:failed], %{count: 1}, %{
          reason: inspect(reason)
        })
    end
  end

  defp safe_parse_uri(str) do
    Ezagent.URI.new!(str)
  rescue
    _ -> :error
  end

  defp session_workspace(%URI{} = session) do
    case Ezagent.Capability.workspace_of(session) do
      %URI{} = ws -> ws
      _ -> :error
    end
  end

  defp caller_uri(ctx) do
    case ctx[:caller] do
      %URI{} = caller -> caller
      _ -> :error
    end
  end

  # 保存全局 GitHub 凭证（admin-gated）。token 写盘收口在 github 插件 Creds——经
  # `gh(:save_creds, …)` dispatch 到 gateway（kanban 不再直写 github.yaml）。
  @doc false
  def save_github_creds(%{access_token: token} = args, ctx) when is_binary(token) do
    if Shared.admin?(ctx) do
      case gh(:save_creds, %{access_token: token, repo: Map.get(args, :repo, "")}, ctx) do
        {:ok, _} -> {:ok, %{}, []}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :unauthorized}
    end
  end

  # 保存全局 Miro 凭证（admin-gated）。
  @doc false
  def save_miro_creds(%{access_token: token} = args, ctx) when is_binary(token) do
    if Shared.admin?(ctx) do
      case Miro.write_creds(%{access_token: token, board_id: Map.get(args, :board_id, "")}) do
        :ok -> {:ok, %{}, []}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :unauthorized}
    end
  end

  # --- 入站 poller 触发接线（session-gated，Phase 2） ------------------

  @doc """
  入站 open-PR poller 的期望态决策（纯函数；用户定的 session-gated 触发模型）：比较看板
  配置写入**前后**两态，得出对 poller 该做什么：

    * `{:bind, repo}` —— 写后 `github_repo` + `session_uri` **都在**（配了 repo + 被绑
      session 驱动）→ 启动 / 重申 poller；
    * `:unbind` —— 写前两者俱全（poller 在跑），写后被清掉一个 → 停 poller；
    * `:noop` —— 本就没跑、现在也不该跑（避免无谓 dispatch / 网关懒种）。

  Public 以便纯逻辑单测断言触发条件（任一态形如 `BoardConfig.read/1` 的返回）。

      iex> alias Ezagent.Behavior.Kanban.Connectors
      iex> none = %{github_repo: nil, session_uri: nil, miro_board: nil}
      iex> both = %{github_repo: "o/r", session_uri: "sess-uri", miro_board: nil}
      iex> Connectors.pr_sync_action(none, both)
      {:bind, "o/r"}
      iex> Connectors.pr_sync_action(both, none)
      :unbind
      iex> Connectors.pr_sync_action(none, none)
      :noop
  """
  @spec pr_sync_action(map(), map()) :: {:bind, String.t()} | :unbind | :noop
  def pr_sync_action(before_cfg, after_cfg) do
    cond do
      session_gated?(after_cfg) -> {:bind, after_cfg.github_repo}
      session_gated?(before_cfg) -> :unbind
      true -> :noop
    end
  end

  # repo + session 俱全 = poller 该跑（入站触发的两层 gate 里"被绑 session"这层 + 配了 repo）。
  defp session_gated?(cfg), do: is_binary(cfg.github_repo) and is_binary(cfg.session_uri)

  # 据前后态决策 → 经已有 `gh/3` dispatch helper 调 github 网关的入站 poller 动作
  # （`bind_pr_sync` / `unbind_pr_sync`，系统身份、跨插件、零编译依赖；poller 进程归 github
  # 插件）。两处调用方（bind_session / set_board_config）写完配置后调它——whichever 后发生都
  # 能把"repo+session 俱全"这态推成 poller 启动。仅在 self_uri 是 %URI{} 时动作（防御）。
  defp reconcile_pr_sync(%URI{} = uri, before_cfg, ctx) do
    # 看板实例 URI 的字符串形式（gateway 经 URI.parse 还原成 poller 注册键）。
    uri_str = URI.to_string(uri)

    case pr_sync_action(before_cfg, BoardConfig.read(uri)) do
      {:bind, repo} ->
        dispatch_pr_sync(:bind_pr_sync, %{kanban_uri: uri_str, repo: repo}, ctx)

      :unbind ->
        dispatch_pr_sync(:unbind_pr_sync, %{kanban_uri: uri_str}, ctx)

      :noop ->
        :ok
    end
  end

  defp reconcile_pr_sync(_uri, _before_cfg, _ctx), do: :ok

  # poller 是辅助入站触发：其 dispatch 失败**不该**让用户的 bind_session/set_board_config
  # 动作失败——故只 log、不回传错误（非静默丢：失败 surface 在 Logger.warning）。
  defp dispatch_pr_sync(action, args, ctx) do
    case gh(action, args, ctx) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "kanban: pr_sync #{action} dispatch failed kanban=#{Map.get(args, :kanban_uri)} " <>
            "reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  # 容错读看板配置（self_uri 非 %URI{} 时给空配置——reconcile 据此判 :noop，不 crash）。
  defp read_cfg(%URI{} = uri), do: BoardConfig.read(uri)
  defp read_cfg(_), do: %{github_repo: nil, session_uri: nil, miro_board: nil}

  # --- 出站 helpers ---------------------------------------------------

  # 每图独立配置：repo 取本图 `BoardConfig`（token 不在 kanban——gateway 内部经 github
  # 插件 Creds 读）。返回 `{:ok, repo}`（repo 非空串）| `{:error, :github_repo_missing}`。
  defp board_repo(ctx) do
    repo =
      case ctx[:self_uri] do
        %URI{} = uri -> BoardConfig.read(uri).github_repo
        _ -> nil
      end

    case repo do
      r when is_binary(r) and r != "" -> {:ok, r}
      _ -> {:error, :github_repo_missing}
    end
  end

  # GitHub 出站 dispatch helper（仿 `MiroSync.do_dispatch`）：先**懒种**确保系统单例
  # github gateway agent 起活，再经 `Ezagent.Invocation.dispatch/1` 调它的
  # `github.<action>`，系统身份（受信后台集成，对齐 MiroSync 用 admin_genesis_cap 的
  # 先例）。`:call` mode 同步拿结果回 handler。`ctx` 携入参符号对齐（caller 身份固定走系统）。
  defp gh(action, args, _ctx) do
    with :ok <- ensure_gateway() do
      # sanctioned 构造（过 uri_query.scan）：with_action 而非裸 `?action=` 串。
      target = Ezagent.URI.with_action(github_gateway_uri(), :github, action)

      Ezagent.Invocation.dispatch(%Ezagent.Invocation{
        target: target,
        mode: :call,
        args: args,
        ctx: %{caller: sys_caller(), caps: sys_caps(), reply: {:caller_inbox, self()}}
      })
    end
  end

  # 懒种系统单例 github gateway agent（仿 kanban-manager 经 `KanbanData.ensure_spawned/1`
  # 的懒种先例：系统单例不在 boot 种——避免 boot 竞态/漏种窗口——而在**首次使用时**确保
  # 存在，此刻节点全 up）。`ensure_started/1` 是 sanctioned 的 owner-gated rehydrate 入口
  # （SnapshotStore 不可被 plugin 直碰，§11 grep gate）：
  #   * 已 live → `{:ok, pid}`（幂等）；
  #   * 有快照（dormant，重启后）→ rehydrate → `{:ok, pid}`；
  #   * 从未创建（无快照）→ `{:error, _}` → `Workspace.create_agent` 系统身份首建。
  defp ensure_gateway do
    uri = github_gateway_uri()

    case Ezagent.LocalRuntime.ensure_started(uri) do
      {:ok, _pid} -> :ok
      {:error, _} -> create_gateway(uri)
    end
  end

  # 首建 gateway agent：flavor `native` × role `github-gateway`（github 插件 `roles/0`
  # 注册的 recipe——按 role 名 dispatch-clean，无编译依赖 github 插件）。已存在（并发
  # race）→ 当成功。create_agent 经 RF-5a role-create 路径（对齐 world `create_kanban`）。
  defp create_gateway(_uri) do
    workspace_uri = Ezagent.URI.workspace(:system)

    create_args = %{
      flavor: "native",
      name: "github_gateway",
      role: "github-gateway",
      cwd: "",
      with_pty: false
    }

    case Ezagent.Workspace.create_agent(workspace_uri, create_args, create_ctx(workspace_uri)) do
      {:ok, %{agent_uri: _}} -> :ok
      {:error, {:already_exists, _}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # create_agent 的 caller ctx（对齐 `mix ezagent.agent.create` 的 operator_admin_ctx）：
  # caller = genesis admin entity，caps = 一条 INLINE `cap(:workspace, Workspace,
  # :create_agent)` scoped 到系统 workspace（step 5.5 authorizer，非 wildcard）。
  defp create_ctx(%URI{scheme: "workspace"} = workspace_uri) do
    admin_uri = sys_caller()

    %{
      caller: admin_uri,
      caps: [
        %Ezagent.Capability{
          Ezagent.Capability.cap(
            :workspace,
            Ezagent.Behavior.Workspace,
            :create_agent,
            Ezagent.URI.instance(workspace_uri),
            Ezagent.Capability.workspace_of(workspace_uri)
          )
          | granted_by: admin_uri,
            granted_at: DateTime.utc_now()
        }
      ]
    }
  end

  # 系统单例 github gateway agent 的 URI（懒种地址；与 github 插件 `gateway_uri/0` 同址）。
  defp github_gateway_uri, do: Ezagent.URI.agent(:system, :github_gateway)

  defp sys_caller, do: Ezagent.URI.user(:system, :admin)
  defp sys_caps, do: MapSet.new([Ezagent.Capability.admin_genesis_cap()])

  # 拼 github issue body：节点 stage/status + inline content 产物。
  defp github_issue_body(n) do
    content =
      (Map.get(n, :artifacts) || [])
      |> Enum.map(&Map.get(&1, :content))
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    "**stage**: #{n.stage} · **status**: #{n.status}\n\n" <>
      content <> "\n\n_由 ezagent kanban 节点出站_"
  end

  # 从节点 pr 产物里抠出 PR 号（"#42"→42）。artifacts 用 atom 键（已 normalize）。
  defp node_pr(node) do
    node
    |> Map.get(:artifacts, [])
    |> Enum.find_value(fn a ->
      if to_string(Map.get(a, :kind)) == "pr" do
        case to_pr_number(to_string(Map.get(a, :ref))) do
          n when is_integer(n) -> n
          _ -> nil
        end
      end
    end)
  end

  defp to_pr_number(pr) when is_integer(pr), do: pr

  defp to_pr_number(pr) when is_binary(pr) do
    case pr |> String.trim() |> String.trim_leading("#") |> Integer.parse() do
      {n, _} -> n
      :error -> :error
    end
  end

  defp to_pr_number(_), do: :error

  # 遍历登记过 PR 的节点查状态；merged/closed 的 set status=done。返回 {新nodes,推进数,连不上?}。
  # 经 gh gateway dispatch 查 PR；任何 {:error,_}（gh 退出/不可用/gateway 未起）→ 标连不上
  # （保守，surface :github_unreachable，非静默丢）。
  defp advance_merged_prs(nodes, repo, ctx) do
    Enum.reduce(nodes, {nodes, 0, false}, fn {id, node}, {acc_nodes, n, unreachable?} ->
      case node_pr(node) do
        nil ->
          {acc_nodes, n, unreachable?}

        pr ->
          case gh(:get_pull, %{repo: repo, number: pr}, ctx) do
            {:ok, %{merged: true}} -> {done_node(acc_nodes, id), n + 1, unreachable?}
            {:ok, %{state: "closed"}} -> {done_node(acc_nodes, id), n + 1, unreachable?}
            {:error, _} -> {acc_nodes, n, true}
            _ -> {acc_nodes, n, unreachable?}
          end
      end
    end)
  end

  defp done_node(nodes, id) do
    case nodes[id] do
      %{owner: o} = node when not is_nil(o) -> Map.put(nodes, id, %{node | status: :done})
      _ -> nodes
    end
  end

  # kanban 实例 URI 的末段名（建 Miro 板默认名用）。
  defp uri_name(%URI{} = uri), do: uri |> URI.to_string() |> String.split("/") |> List.last()
  defp uri_name(_), do: "kanban"

  # GitHub 失败 → 干净错误 atom（前端 dispatchError 映射成中文提示）。
  defp gh_reason({:http_status, code, _}) when code in [401, 403], do: :github_unauthorized
  defp gh_reason({:http_status, 404, _}), do: :github_not_found
  defp gh_reason({:http_status, code, _}), do: String.to_atom("github_http_#{code}")
  defp gh_reason({:http_error, _}), do: :github_unreachable
  defp gh_reason(other) when is_atom(other), do: other
  defp gh_reason(other), do: {:github_error, other}
end
