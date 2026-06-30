defmodule Ezagent.Behavior.Github do
  @moduledoc """
  GitHub 网关 Behavior（出站可 dispatch）——薄包 `EzagentPluginGithub.Gh.*`。

  本 Behavior 是**通用 github 网关**：任何 plugin/agent 经
  `Ezagent.Invocation.dispatch/1` 调 `github.<action>`（kanban 是首个消费者，经
  dispatch 而非跨插件直调，守不变式 #8）。挂在 boot 期种下的系统单例 gateway agent
  （`entity://system/agent/github_gateway`，flavor `native` × role `github-gateway`）上，
  per-instance 加载在通用 `Entity.Agent` 宿主（同 kanban-as-role 范式）。

  ## 无持久状态（纯出站网关）

  `use Ezagent.Lifecycle`，**无 state / 无 transients**：每个 `handle_<action>/2` 是
  `(args, ctx) → {:ok, result, []}` 的纯转发——出站 IO（`System.cmd("gh", …)`）在
  Kind 进程内同步调（拿结果拼回返回值，对齐 kanban `Connectors` 内联出站先例），不写
  任何快照（空 effect 列表）。故不需要 `create/1`（用宏默认 `{:ok, %{}}`）。

  ## token（per-identity，T8）

  出站动作按 **`ctx.caller`** 选 token——`Creds.token_for_caller/1` 读 caller 自己
  Agent Kind `:api_keys` slice 的 `"github"` PAT：配了 → 用 caller 自己的；没配 →
  `nil` 落 `Gh.*` 的全局 fallback（`system://credentials/github.yaml`，再没配落 gh
  自带 auth）。**token 跟 identity 走，cap 只表示「能用 github 工具」**（per-identity
  存/写的 data-owner gate 复用 `Ezagent.Behavior.ApiKeys`，不另造机制）。

  `save_creds` 动作把**全局**凭证写盘收口在本插件 `Creds`（kanban 不再写 github.yaml，
  token 读写全归 github 插件）；入站 poller（`PrSync`）系统级轮询、不 per-identity，走全局。

  ## 授权

  per-INSTANCE cap 收口（`data_owner/1 → :no_owner`，同 `Terminable`/`Kanban`）。
  `required_caps/0` 的 kind 轴声明 `:any`：运行时（`Kind.Runtime` check 11b）按目标宿主
  type_name 替换（`Entity.Agent → :agent`）——硬写 `:agent` 会让 role×native 路必拒
  （recipe 铸出的 held cap kind 是 `:agent`，但 cap-template 不带 kind）。
  """

  use Ezagent.Lifecycle

  alias EzagentPluginGithub.Creds
  alias EzagentPluginGithub.Gh
  alias EzagentPluginGithub.PrSync

  action(:create_issue,
    args: %{repo: :string, title: :string, body: :string},
    returns: %{number: :integer, url: :string},
    caps: [:create_issue],
    modes: [:call],
    description: "在 repo(owner/name) 建一个 issue"
  )

  action(:post_comment,
    args: %{repo: :string, number: :integer, body: :string},
    returns: %{url: :string},
    caps: [:post_comment],
    modes: [:call],
    description: "在 issue/PR(#number) 下 post 一条评论"
  )

  action(:get_pull,
    args: %{repo: :string, number: :integer},
    returns: %{state: :string, merged: :boolean, head_ref: :string, head_sha: :string},
    caps: [:get_pull],
    modes: [:call],
    description: "读一个 PR 的状态（state/merged/head 分支/head sha）"
  )

  action(:create_commit_status,
    args: %{repo: :string, sha: :string, state: :string, context: :string, description: :string},
    returns: %{url: :string},
    caps: [:create_commit_status],
    modes: [:call],
    description: "推一个 commit status check 到某 sha（硬 CI 门，通用能力）"
  )

  action(:list_open_prs,
    args: %{repo: :string},
    returns: %{prs: {:list, :map}},
    caps: [:list_open_prs],
    modes: [:call],
    description: "列出 repo 的 open PR（入站轮询用）"
  )

  action(:save_creds,
    args: %{access_token: :string, repo: :string},
    returns: %{},
    caps: [:save_creds],
    modes: [:call],
    description: "保存全局 GitHub 凭证（token 写收口在本插件 Creds，落 system 凭证库）"
  )

  action(:bind_pr_sync,
    args: %{kanban_uri: :string, repo: :string},
    returns: %{},
    caps: [:bind_pr_sync],
    modes: [:call],
    description: "启动某看板的 open-PR 入站轮询 poller（薄包 PrSync.bind；入站触发，幂等）"
  )

  action(:unbind_pr_sync,
    args: %{kanban_uri: :string},
    returns: %{},
    caps: [:unbind_pr_sync],
    modes: [:call],
    description: "停某看板的 open-PR 入站轮询 poller（薄包 PrSync.unbind；幂等）"
  )

  # required_caps/0（plugin_check check 10/11 强制）：每个动作一个 `:any`-kind 的
  # `%Capability{}`（运行时按宿主 type_name 替换成 `:agent`）。
  @doc false
  def required_caps do
    for a <- [
          :create_issue,
          :post_comment,
          :get_pull,
          :create_commit_status,
          :list_open_prs,
          :save_creds,
          :bind_pr_sync,
          :unbind_pr_sync
        ],
        into: %{},
        do: {a, Ezagent.Capability.cap(:any, __MODULE__, a)}
  end

  # data_owner 是 per-INSTANCE（实例级 cap 收口）。
  @doc false
  def data_owner(_), do: :no_owner

  # ---------------------------------------------------------------
  # 出站动作 handlers（薄包 Gh.*；纯转发，无快照——空 effect 列表）
  # ---------------------------------------------------------------

  @doc false
  def handle_create_issue(%{repo: repo, title: title, body: body}, ctx) do
    case Gh.create_issue(repo, title, body, caller_token(ctx)) do
      {:ok, %{number: num, url: url}} -> {:ok, %{number: num, url: url}, []}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def handle_post_comment(%{repo: repo, number: number, body: body}, ctx) do
    case Gh.post_comment(repo, number, body, caller_token(ctx)) do
      {:ok, %{url: url}} -> {:ok, %{url: url}, []}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def handle_get_pull(%{repo: repo, number: number}, ctx) do
    case Gh.get_pull(repo, number, caller_token(ctx)) do
      {:ok, pull} when is_map(pull) -> {:ok, pull, []}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def handle_create_commit_status(
        %{repo: repo, sha: sha, state: state, context: context, description: description},
        ctx
      ) do
    case Gh.create_commit_status(repo, sha, state, context, description, caller_token(ctx)) do
      {:ok, %{url: url}} -> {:ok, %{url: url}, []}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def handle_list_open_prs(%{repo: repo}, ctx) do
    case Gh.list_open_prs(repo, caller_token(ctx)) do
      {:ok, prs} when is_list(prs) -> {:ok, %{prs: prs}, []}
      {:error, reason} -> {:error, reason}
    end
  end

  # per-identity token 选择（T8）：caller 配了自己的 github PAT → 用之；没配 → nil
  # （`Gh.*` 落全局 fallback）。`ctx.caller` 由 dispatch 在 Kind.Runtime 注入。
  defp caller_token(ctx) do
    case Creds.token_for_caller(Map.get(ctx, :caller)) do
      {:ok, token} -> token
      :none -> nil
    end
  end

  # 凭证写盘收口在本插件 Creds（同插件直调，非跨插件）。admin-gating 在调用方
  # （kanban `Connectors.save_github_creds`）把关；dispatch 身份的 cap 在 step 5.5 收口。
  @doc false
  def handle_save_creds(%{access_token: token} = args, _ctx) when is_binary(token) do
    case Creds.write(%{access_token: token, repo: Map.get(args, :repo, "")}) do
      :ok -> {:ok, %{}, []}
      {:error, reason} -> {:error, reason}
    end
  end

  def handle_save_creds(_args, _ctx), do: {:error, :access_token_required}

  # ---------------------------------------------------------------
  # 入站轮询绑定（薄包 PrSync.bind/unbind）——本网关是 github 插件的 dispatch 门面，
  # 故"启动/停止某看板的 open-PR 入站 poller"也经 `github.<action>` dispatch 进来：
  # poller 进程归本插件监督树（PrSync），消费者（kanban）零编译依赖。`kanban_uri` 是被绑
  # 看板的实例 URI 串（运行时入参=真 canonical entity:// URI，非字面量），经
  # `Ezagent.URI.new!/1`（canonical 模块，返裸 %URI{}、校验 3seg；非 stdlib URI.parse/new!
  # — UriCanonicalizationInvariant §5.1）还原成 poller 的注册键。
  # ---------------------------------------------------------------

  @doc false
  def handle_bind_pr_sync(%{kanban_uri: kanban_uri, repo: repo}, _ctx)
      when is_binary(kanban_uri) and is_binary(repo) do
    case PrSync.bind(Ezagent.URI.new!(kanban_uri), repo, []) do
      {:ok, _pid} -> {:ok, %{}, []}
      {:ok, _pid, _info} -> {:ok, %{}, []}
      # 已在轮询该板 → 幂等成功（reconcile 可能重复 affirm 同一态）。
      {:error, {:already_started, _pid}} -> {:ok, %{}, []}
      {:error, reason} -> {:error, reason}
    end
  end

  def handle_bind_pr_sync(_args, _ctx), do: {:error, :kanban_uri_and_repo_required}

  @doc false
  def handle_unbind_pr_sync(%{kanban_uri: kanban_uri}, _ctx) when is_binary(kanban_uri) do
    _ = PrSync.unbind(Ezagent.URI.new!(kanban_uri))
    {:ok, %{}, []}
  catch
    # poller 不在（从未绑 / 已解绑）→ unbind 落到无主名 GenServer.call 触发 :noproc exit。
    # 解绑幂等：无可停的也算"已停"，返回成功——这是预期态、非错误，不是静默丢。
    :exit, _ -> {:ok, %{}, []}
  end

  def handle_unbind_pr_sync(_args, _ctx), do: {:error, :kanban_uri_required}
end
