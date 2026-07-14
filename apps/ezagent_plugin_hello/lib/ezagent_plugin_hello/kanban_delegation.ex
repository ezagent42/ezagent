defmodule EzagentPluginHello.KanbanDelegation do
  @moduledoc """
  Hello-owned, loose-coupled delegation into a workspace's canonical Kanban.

  The service never writes Kanban state directly: board creation goes through
  `Ezagent.Workspace.create_agent/3` and every board mutation is an Invocation.
  Caller caps are read from the authenticated principal, preserving Kanban's
  admin-only structural-root and per-node authorization rules.
  """

  require Logger

  alias Ezagent.{Capability, Identity, Invocation, Workspace}
  alias Ezagent.Agent.RecipeResolver
  alias EzagentPluginHello.{Members, TurnDriver}

  @canonical_name "hello-kanban"
  @max_instruction 500

  @doc "Start a supervised hello-to-Kanban delegation and report its result in chat."
  @spec start(URI.t(), String.t(), URI.t()) :: {:ok, pid()} | {:error, term()}
  def start(%URI{} = session_uri, instruction, %URI{} = sender_uri)
      when is_binary(instruction) do
    Task.Supervisor.start_child(EzagentPluginHello.TaskSupervisor, fn ->
      report(session_uri, instruction, sender_uri)
    end)
  end

  @doc "Delegate one instruction under the authenticated sender's persisted capabilities."
  @spec delegate(URI.t(), String.t(), URI.t()) ::
          {:ok, %{kanban_uri: URI.t(), node_id: String.t(), path: String.t()}}
          | {:error, term()}
  def delegate(%URI{} = session_uri, instruction, %URI{} = sender_uri)
      when is_binary(instruction) do
    instruction = instruction |> String.trim() |> String.slice(0, @max_instruction)
    workspace_uri = Capability.workspace_of(session_uri)
    ctx = caller_ctx(sender_uri)

    with true <- instruction != "" || {:error, :instruction_required},
         true <-
           same_workspace_or_admin?(sender_uri, workspace_uri, ctx) ||
             {:error, :cross_workspace_denied},
         {:ok, kanban_uri} <- resolve_default(workspace_uri, ctx),
         {:ok, parent_id} <- root_id(kanban_uri, ctx),
         {:ok, %{id: node_id}} <-
           dispatch(kanban_uri, :add_node, %{parent_id: parent_id || "", title: instruction}, ctx),
         {:ok, _} <-
           dispatch(
             kanban_uri,
             :attach_artifact,
             %{id: node_id, artifact: source_artifact(session_uri, instruction)},
             ctx
           ) do
      {:ok,
       %{
         kanban_uri: kanban_uri,
         node_id: node_id,
         path: "/plugins/kanban/" <> URI.encode_www_form(URI.to_string(kanban_uri))
       }}
    end
  rescue
    ArgumentError -> {:error, :invalid_session_workspace}
  end

  @doc "Resolve the workspace's sole or explicitly canonical `kanban-manager` board."
  @spec resolve_default(URI.t(), map()) :: {:ok, URI.t()} | {:error, term()}
  def resolve_default(%URI{scheme: "workspace"} = workspace_uri, ctx) do
    case RecipeResolver.list_by_recipe("kanban-manager", workspace_uri) do
      [] -> create_default(workspace_uri, ctx)
      [kanban_uri] -> {:ok, kanban_uri}
      kanban_uris -> select_canonical(kanban_uris)
    end
  end

  defp create_default(workspace_uri, ctx) do
    case Workspace.create_agent(
           workspace_uri,
           %{
             flavor: "native",
             name: @canonical_name,
             role: "kanban-manager",
             cwd: "",
             with_pty: false
           },
           ctx
         ) do
      {:ok, %{agent_uri: kanban_uri}} -> {:ok, kanban_uri}
      {:error, reason} -> {:error, reason}
    end
  end

  defp select_canonical(kanban_uris) do
    matches = Enum.filter(kanban_uris, &(entity_name(&1) == @canonical_name))

    case matches do
      [kanban_uri] -> {:ok, kanban_uri}
      _ -> {:error, :ambiguous_default_kanban}
    end
  end

  defp root_id(kanban_uri, ctx) do
    case dispatch(kanban_uri, :get_tree, %{}, ctx) do
      {:ok, %{tree: %{root_id: root_id}}} -> {:ok, root_id}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_kanban_tree, other}}
    end
  end

  defp source_artifact(session_uri, instruction) do
    content =
      Jason.encode!(%{
        "session_uri" => uri_to_string(session_uri),
        "page_summary" => page_summary(session_uri),
        "instruction" => instruction
      })

    %{
      "tool" => "hello",
      "kind" => "hello_source",
      "ref" => uri_to_string(session_uri),
      "url" => page_url(session_uri),
      "content" => content
    }
  end

  defp page_url(%URI{} = session_uri) do
    case Ezagent.URI.name(session_uri) do
      {:ok, name} -> "/hello/" <> URI.encode_www_form(name)
      :error -> "/hello/"
    end
  end

  defp page_summary(session_uri) do
    case Ezagent.Kind.get_slice(session_uri, :surface) do
      {:ok, %{versions: versions, approved: approved}} when is_map(versions) ->
        versions
        |> Map.get(approved, %{})
        |> Map.get(:tree, %{})
        |> inspect(limit: 20, printable_limit: 300)
        |> String.slice(0, 500)

      _ ->
        "Hello page"
    end
  end

  defp caller_ctx(sender_uri) do
    %{
      caller: sender_uri,
      caps: sender_uri |> Identity.read_entity_caps() |> MapSet.new(),
      reply: {:caller_inbox, self()}
    }
  end

  defp same_workspace_or_admin?(sender_uri, workspace_uri, ctx) do
    admin? = MapSet.member?(ctx.caps, Capability.admin_genesis_cap())
    admin? || Capability.workspace_of(sender_uri) == workspace_uri
  rescue
    ArgumentError -> false
  end

  defp dispatch(kanban_uri, action, args, ctx) do
    Invocation.dispatch(%Invocation{
      target: Ezagent.URI.with_action(kanban_uri, :kanban, action),
      mode: :call,
      args: args,
      ctx: ctx
    })
  end

  defp report(session_uri, instruction, sender_uri) do
    actor =
      case Members.role_uri(session_uri, "dispatcher") do
        {:ok, uri} -> uri
        _ -> sender_uri
      end

    case delegate(session_uri, instruction, sender_uri) do
      {:ok, result} ->
        TurnDriver.say_nav(
          session_uri,
          actor,
          "已交给 Kanban：#{instruction}",
          %{"type" => "open_url", "value" => result.path}
        )

      {:error, reason} ->
        Logger.warning("hello Kanban delegation failed: #{inspect(reason)}")
        TurnDriver.say(session_uri, actor, "未能交给 Kanban：#{format_reason(reason)}")
    end
  end

  defp format_reason(:ambiguous_default_kanban), do: "工作区存在多个看板，且未设置默认看板"
  defp format_reason(:forbidden), do: "当前账号没有创建看板任务的权限"
  defp format_reason(:unauthorized), do: "请先登录后再试"
  defp format_reason(_reason), do: "服务暂时不可用，请稍后再试"

  defp entity_name(%URI{} = entity_uri) do
    case Ezagent.URI.name(entity_uri) do
      {:ok, name} -> name
      :error -> nil
    end
  end

  defp uri_to_string(%URI{} = uri), do: URI.to_string(uri)
end
