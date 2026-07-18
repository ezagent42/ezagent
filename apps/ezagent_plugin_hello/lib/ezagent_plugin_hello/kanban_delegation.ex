defmodule EzagentPluginHello.KanbanDelegation do
  @moduledoc """
  Hello-owned, loose-coupled delegation into a workspace's canonical Kanban.

  The service never writes Kanban state directly: board creation goes through
  `Ezagent.Workspace.create_agent/3` and every board mutation is an Invocation.
  Caller caps are read from the authenticated principal, preserving Kanban's
  admin-only structural-root and per-node authorization rules.
  """

  require Logger
  use Gettext, backend: EzagentPluginHello.Gettext

  alias Ezagent.{Capability, Invocation, Workspace}
  alias Ezagent.Agent.RecipeResolver
  alias EzagentPluginHello.{KanbanPublishedRead, Members, TurnDriver}

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
          {:ok,
           %{
             kanban_uri: URI.t(),
             live_board_url: String.t(),
             node_id: String.t(),
             path: String.t(),
             publication_revision: pos_integer(),
             title: String.t(),
             status: atom() | nil
           }}
          | {:error, term()}
  def delegate(%URI{} = session_uri, instruction, %URI{} = sender_uri)
      when is_binary(instruction) do
    instruction = instruction |> String.trim() |> String.slice(0, @max_instruction)
    workspace_uri = Capability.workspace_of(session_uri)

    with true <- instruction != "" || {:error, :instruction_required},
         {:ok, workspace_ctx} <- workspace_ctx(sender_uri, workspace_uri),
         {:ok, kanban_uri} <- resolve_default(workspace_uri, workspace_ctx),
         {:ok, ctx} <- board_ctx(sender_uri, kanban_uri),
         {:ok, parent_id} <- root_id(kanban_uri, ctx),
         {:ok, %{id: node_id}} <-
           dispatch(kanban_uri, :add_node, %{parent_id: parent_id || "", title: instruction}, ctx),
         {:ok, _} <-
           dispatch(
             kanban_uri,
             :attach_artifact,
             %{id: node_id, artifact: source_artifact(session_uri, instruction)},
             ctx
           ),
         {:ok, task} <- task_snapshot(kanban_uri, node_id, ctx),
         {:ok, published_ref} <-
           KanbanPublishedRead.publish_board_read(ctx, session_uri, kanban_uri) do
      {:ok,
       %{
         kanban_uri: kanban_uri,
         live_board_url: world_kanban_url(kanban_uri),
         node_id: node_id,
         title: Map.get(task, :title, instruction),
         status: Map.get(task, :status),
         path: published_ref.receive_ref,
         publication_revision: published_ref.revision
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

  defp task_snapshot(kanban_uri, node_id, ctx) do
    case dispatch(kanban_uri, :get_tree, %{}, ctx) do
      {:ok, %{tree: %{nodes: nodes}}} when is_map(nodes) ->
        case Map.fetch(nodes, node_id) do
          {:ok, node} -> {:ok, node}
          :error -> {:error, :delegated_node_missing}
        end

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:invalid_kanban_tree, other}}
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

  defp workspace_ctx(sender_uri, workspace_uri) do
    requested =
      Capability.cap(:workspace, :any, :any, Ezagent.URI.instance(workspace_uri), workspace_uri)

    issue_ctx(sender_uri, requested)
  end

  defp board_ctx(sender_uri, board_uri) do
    requested =
      Capability.cap(
        :agent,
        Ezagent.ActionSet.Kanban,
        :any,
        Ezagent.URI.instance(board_uri),
        Capability.workspace_of(board_uri)
      )

    issue_ctx(sender_uri, requested)
  end

  defp issue_ctx(sender_uri, requested) do
    authorization =
      if Ezagent.Identity.admin?(sender_uri),
        do: {:admin, sender_uri},
        else: {:held_by, sender_uri}

    case Ezagent.Cap.issue(authorization, sender_uri, requested) do
      {:ok, cap} ->
        {:ok, %{caller: sender_uri, caps: MapSet.new([cap]), reply: {:caller_inbox, self()}}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp dispatch(kanban_uri, action, args, ctx) do
    Invocation.dispatch(%Invocation{
      target: Ezagent.URI.with_action(kanban_uri, :kanban, action),
      mode: :call,
      args: args,
      ctx: ctx,
      origin: :trusted_internal
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
          gettext("Delegated to Kanban: %{instruction}", instruction: instruction),
          %{
            "type" => "open_url",
            "value" => result.path,
            "kind" => "hello_kanban_receipt",
            "live_board_url" => result.live_board_url,
            "snapshot" => true,
            "board_uri" => uri_to_string(result.kanban_uri),
            "node_id" => result.node_id,
            "publication_revision" => result.publication_revision,
            "title" => result.title,
            "status" => to_string(result.status || :unknown)
          }
        )

      {:error, reason} ->
        Logger.warning("hello Kanban delegation failed: #{inspect(reason)}")

        # G5 source 2 — structured error (context tag + raw reason); the
        # shared error surface renders the per-viewer card (Layer 3 until a
        # code is registered for this tag).
        TurnDriver.say_error(session_uri, actor, {:kanban_delegation_failed, reason})
    end
  end

  defp entity_name(%URI{} = entity_uri) do
    case Ezagent.URI.name(entity_uri) do
      {:ok, name} -> name
      :error -> nil
    end
  end

  defp world_kanban_url(%URI{} = kanban_uri) do
    "/plugins/kanban/" <> URI.encode_www_form(URI.to_string(kanban_uri))
  end

  defp uri_to_string(%URI{} = uri), do: URI.to_string(uri)
end
