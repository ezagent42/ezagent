defmodule EzagentPluginLoom.Template.LoomSession do
  @moduledoc """
  `session.loom` Template Class.

  Materialize 一个 domain-owned、socialware-subset 的 `Ezagent.Entity.Session`,并把它的
  chat working copy 标注上 loom vertical metadata (node_types / roles / sample_tree)。

  instantiate 还装配 **agent team**(`EzagentPluginLoom.Team.ensure_team` —— orchestrator /
  v0 / worker / meta / stitch 作为 Session Member,admin Members 面板可见)+ seed 一张初始页
  (`OrchestratorServer.seed_page`,fork 出的 session `no_seed` 跳过)。编排控制器留 loom 自实现;
  调 LLM 统一走 `EzagentPluginLoom.LLM`(已对接 socialware/ezagent)。
  """

  @behaviour Ezagent.Kind.Template
  # 让 `session.loom` 出现在 admin "/workspaces/:name → add template" 下拉里:
  # `Ezagent.UI.Form.list_form_classes/0` 只收录实现了 `Ezagent.UI.Form` 的 template class
  # (curl.agent 同此做法)。仅声明字段,框架自动渲表单 + `default_form_to_args` 注入 "class"。
  @behaviour Ezagent.UI.Form

  alias Ezagent.{Invocation, KindRegistry, WorkspaceRegistry}
  alias Ezagent.Entity.{Session, User}
  alias EzagentPluginLoom.NodeTypes

  @impl Ezagent.Kind.Template
  def template_name, do: "session.loom"

  # 表单只暴露 session_name(对齐 loom-stitch:loom 字段只有这一个)。operator_uri 可选,
  # 缺省时 instantiate 默认 workspace admin —— class 由 default_form_to_args 自动注入。
  @impl Ezagent.UI.Form
  def form_fields do
    [
      %{
        name: "session_name",
        type: :text,
        label: "Session 名称(short name)",
        required: true,
        placeholder: "main"
      }
    ]
  end

  @impl Ezagent.Kind.Template
  def validate(tmpl) when is_map(tmpl) do
    with :ok <- check_class(tmpl),
         :ok <- check_session_name(tmpl),
         :ok <- check_operator_uri(tmpl) do
      :ok
    end
  end

  def validate(_), do: {:error, :not_a_map}

  @impl Ezagent.Kind.Template
  def instantiate(
        _tmpl_name,
        %{"session_name" => session_name} = tmpl,
        %URI{} = workspace_uri
      ) do
    workspace_name = Ezagent.URI.workspace_name!(workspace_uri)
    session_uri = Ezagent.URI.session(workspace_name, :loom, session_name)
    operator_uri = resolve_operator_uri(tmpl, workspace_name)

    case ensure_session(session_uri) do
      {:ok, fresh?} ->
        with :ok <- WorkspaceRegistry.bind(session_uri, workspace_uri),
             {:ok, _} <-
               Ezagent.Behavior.Session.system_set_working_copy(
                 session_uri,
                 working_copy(tmpl, operator_uri)
               ),
             :ok <- ensure_operator_user(operator_uri),
             {:ok, _} <- join_operator(session_uri, operator_uri) do
          _ = start_orchestrator(session_uri)
          # agent team:起一队 loom 编排控制器作为 Member(admin Members 面板可见)。
          _ = EzagentPluginLoom.Team.ensure_team(session_uri)

          # seed 初始页 → 打开 loom 不再空白("operator 批准后显示")。best-effort。
          # fork 出的 session 自带源页(`no_seed`)跳过;`saved_template` 则 seed 已存模板页。
          if Map.get(tmpl, "no_seed") != true,
            do:
              EzagentPluginLoom.OrchestratorServer.seed_page(
                session_uri,
                saved_template_tree(tmpl, workspace_name)
              )

          {:ok, [session_uri], %{fresh?: fresh?, vertical: :loom}}
        else
          {:error, _reason} = error ->
            cleanup_if_fresh(session_uri, fresh?)
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  def instantiate(_tmpl_name, tmpl, _workspace_uri), do: {:error, {:invalid_template, tmpl}}

  defp check_class(%{"class" => "session.loom"}), do: :ok
  defp check_class(%{"class" => other}), do: {:error, {:wrong_class, other}}
  defp check_class(_), do: {:error, :missing_class_field}

  defp check_session_name(%{"session_name" => name}) when is_binary(name) and name != "",
    do: :ok

  defp check_session_name(_), do: {:error, :missing_session_name}

  # operator_uri 可选(对齐 loom-stitch:它无 operator 概念)。提供则必须是合法 user entity URI;
  # 空串/缺省 → :ok(instantiate 默认 workspace admin)。
  defp check_operator_uri(%{"operator_uri" => uri}) when is_binary(uri) and uri != "" do
    case parse_user_uri(uri) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp check_operator_uri(%{"operator_uri" => ""}), do: :ok
  defp check_operator_uri(%{"operator_uri" => nil}), do: :ok
  defp check_operator_uri(%{"operator_uri" => _}), do: {:error, :bad_operator_uri}
  defp check_operator_uri(_), do: :ok

  defp parse_user_uri(uri_str) do
    uri = Ezagent.URI.new!(uri_str)

    if uri.scheme == "entity" and Ezagent.URI.type?(uri, :user) do
      {:ok, uri}
    else
      {:error, {:invalid_operator_uri, uri_str}}
    end
  rescue
    ArgumentError -> {:error, :bad_operator_uri}
  end

  # operator_uri:tmpl 提供则用;否则默认同 workspace 的 admin(`entity://<ws>/user/admin`)——
  # 同域避免 join 跨 prefix 成员校验问题。loom-stitch 无 operator,此默认是迁移的兼容兜底。
  defp resolve_operator_uri(%{"operator_uri" => uri_str}, _workspace_name)
       when is_binary(uri_str) and uri_str != "" do
    {:ok, uri} = parse_user_uri(uri_str)
    uri
  end

  defp resolve_operator_uri(_tmpl, workspace_name) do
    Ezagent.URI.user(workspace_name, "admin")
  end

  # `saved_template` 入参 → 取该 workspace 已存模板的 page tree(供 seed);无则 nil(用默认 starter)。
  defp saved_template_tree(%{"saved_template" => name}, workspace_name)
       when is_binary(name) and name != "" do
    case EzagentPluginLoom.SavedTemplates.get(workspace_name, name) do
      %{tree: tree} -> tree
      _ -> nil
    end
  end

  defp saved_template_tree(_tmpl, _ws), do: nil

  defp ensure_session(session_uri) do
    # 同 advisor: spawn 统一 `Entity.Session` Kind,显式线程 SOCIALWARE subset
    # (`Session.socialware_behaviors/0` = {Session, Turn, Surface, Publisher}),
    # 故 Turn/Surface 在 loom 实例上 ACTIVE、ExternalMirror 排除。
    case Ezagent.Kind.spawn(Session, %{
           uri: session_uri,
           behaviors: Session.socialware_behaviors()
         }) do
      {:ok, _pid} -> {:ok, true}
      {:error, {:already_started, _pid}} -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  end

  defp working_copy(tmpl, %URI{} = operator_uri) do
    %{
      "class" => template_name(),
      "vertical" => "loom",
      "session_name" => Map.fetch!(tmpl, "session_name"),
      "operator_uri" => URI.to_string(operator_uri),
      "roles" => NodeTypes.default_roles(),
      "node_types" => NodeTypes.node_types(),
      "sample_tree" => NodeTypes.sample_tree()
    }
  end

  defp ensure_operator_user(%URI{} = operator_uri) do
    case KindRegistry.lookup(operator_uri) do
      {:ok, _pid} ->
        :ok

      :error ->
        case Ezagent.Kind.spawn(User, %{
               uri: operator_uri,
               initial_caps: User.initial_caps_for_spawn(operator_uri)
             }) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp join_operator(session_uri, operator_uri) do
    Invocation.dispatch(%Invocation{
      target: Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=session.join"),
      mode: :call,
      args: %{member: operator_uri, role_name: "operator", in_session_template: true},
      ctx: %{
        caller: Ezagent.SystemPrincipal.uri("template-materialize"),
        caps:
          "template-materialize"
          |> Ezagent.SystemPrincipal.uri()
          |> Ezagent.SystemPrincipal.caps(),
        reply: {:caller_inbox, self()}
      }
    })
  end

  # 起 per-session 编排进程(订阅 session 事件 → 真实 LLM 编排)。生产接线:loom session
  # 一经 materialize 即具备 multi-agent 编排能力。supervisor 缺失/已起都容错(隔离测试/幂等)。
  defp start_orchestrator(session_uri) do
    DynamicSupervisor.start_child(
      EzagentPluginLoom.OrchestratorSupervisor,
      {EzagentPluginLoom.OrchestratorServer, session_uri}
    )
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp cleanup_if_fresh(_session_uri, false), do: :ok

  defp cleanup_if_fresh(session_uri, true) do
    _ = Ezagent.Kind.terminate(session_uri)
    :ok
  end
end
