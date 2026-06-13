defmodule Ezagent.Orchestrator.McpServer do
  @moduledoc """
  Orchestrator MCP **transport** — the cc-plugin request-plumbing a live
  `claude` orchestrator reaches its 7 management tools through.

  ## Transport, NOT operations (decomposition spec §3.4 / O-4)

  This module is the cc plugin's MCP TRANSPORT only. It does THREE things:

  1. **`tools/list` schema** — `tool_schemas/0` returns the MCP
     `tools/list`-shaped descriptor for the 9 tools
     (`Ezagent.Orchestrator.McpServer.ToolCatalog`). Pure transport wire
     format.
  2. **`tools/call` decode + forward** — `handle_tool_call/3` DECODES the
     wire `{tool, arguments}`, then FORWARDS it via
     `Ezagent.Invocation.dispatch` to the SESSION-domain action
     `session://…?action=orchestrate.<tool>`
     (`Ezagent.Behavior.OrchestratorTools`). It carries ONLY the
     orchestrator's caller URI — **NO capability authority crosses the
     plugin boundary**. The session action reconstructs the orchestrator's
     4 delegated caps SESSION-side and runs the op (O-4). This is a runtime
     dispatch edge (cc → session), the same shape as the cc `reply` tool
     dispatching `session.send`; NOT a compile dependency.
  3. **Result encode** — maps the dispatched action's raw
     `{:ok, value}` / `{:error, reason}` result to the MCP-shaped
     success / structured-tool-error map the orchestrator LLM sees.

  The session-mutating OPERATIONS (`Ezagent.Orchestrator.Tools` + the
  `Ezagent.Orchestrator.ToolRunner` value-form core) live in
  `domain.session` (`ezagent_domain_instance_message`) — they MUTATE
  session/routing state. This module holds ZERO operation logic and NEVER
  calls `Ezagent.Orchestrator.Tools` directly; it dispatches.

  ## The bound context — orchestrator URI + its session URI

  `%McpServer{}` binds only the routing context the transport needs to
  ADDRESS the dispatch: the calling orchestrator's URI (→ `ctx.caller`) and
  its session URI (→ the dispatch target). It carries NO caps, owner, or
  parent-template — those are session-domain authority/context the session
  action reconstructs. The context is bound ESR-side, never trusted from
  the wire.

  ## How a live `claude` orchestrator reaches it

  A `claude` agent talks to MCP servers listed in its `--mcp-config`. The
  cc-orchestrator AgentTemplate's `operator_mcp_config_path` points at a
  config whose stdio command runs `priv/orchestrator_bridge.py`, which:

  - presents `tool_schemas/0` on `tools/list`;
  - on `tools/call`, forwards `{tool, arguments}` to the orchestrator's
    ESR-side `McpChannel` over the existing WebSocket;
  - the ESR side runs `handle_tool_call/3` against THIS server's bound
    context (orchestrator URI + session URI) and returns the structured
    MCP result.

  The bound context is resolved ESR-side from the token-authenticated agent
  URI (`from_orchestrator_uri/1`), never from the wire.
  """

  use GenServer

  require Logger

  alias Ezagent.Orchestrator.McpServer.ToolCatalog
  alias Ezagent.Orchestrator.ToolRunner

  @enforce_keys [:orchestrator_uri, :session_uri]
  defstruct [:orchestrator_uri, :session_uri]

  @type t :: %__MODULE__{
          orchestrator_uri: URI.t(),
          session_uri: URI.t()
        }

  # --- construction ------------------------------------------------------

  @doc """
  Build the bound transport context (value form).

  Required opts:
  - `:orchestrator_uri` — `%URI{}` of the orchestrator agent (→ `ctx.caller`)
  - `:session_uri` — `%URI{}` of the orchestrator's session (the dispatch
    target's instance)

  No caps / owner / parent-template are bound — the session action
  reconstructs the orchestrator's delegated caps + template context
  session-side (O-4).
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) do
    with {:ok, orchestrator_uri} <- fetch_uri(opts, :orchestrator_uri),
         {:ok, session_uri} <- fetch_uri(opts, :session_uri) do
      {:ok, %__MODULE__{orchestrator_uri: orchestrator_uri, session_uri: session_uri}}
    end
  end

  @doc """
  Build the bound transport context for `orchestrator_uri` ALONE — the
  entry point the orchestrator MCP bridge's Channel
  (`Ezagent.Orchestrator.McpChannel`) uses.

  A `claude`-launched bridge can only present the orchestrator's agent URI
  (token-authenticated by `Ezagent.Orchestrator.McpSocket`). It cannot —
  and must not — supply the session URI: this function resolves it
  ESR-side via `Ezagent.Orchestrator.McpRegistry.lookup/1` (the binding the
  Generator registered), lazily REBUILDING from the durable Session
  snapshot on an ETS miss (Task #110 read-through cache; survives a phx
  restart that emptied ETS).

  Returns `{:error, :orchestrator_not_registered}` when no durable Session
  snapshot maps back to this orchestrator URI (a valid agent URI that is
  not — and never was — a registered orchestrator → fail-closed).
  """
  @spec from_orchestrator_uri(URI.t()) :: {:ok, t()} | {:error, term()}
  def from_orchestrator_uri(%URI{} = orchestrator_uri) do
    case Ezagent.Orchestrator.McpRegistry.lookup(orchestrator_uri) do
      {:ok, ctx} ->
        new(orchestrator_uri: orchestrator_uri, session_uri: ctx.session_uri)

      :error ->
        rebuild_from_durable(orchestrator_uri)
    end
  end

  # ETS MISS path: resolve the orchestrator's session URI from the durable
  # `kind_snapshots` rows, fill the cache, and bind. Reads the PERSISTED
  # snapshot (not the live Session Kind) deliberately — the bridge may join
  # before the Session has cold-spawned, and the snapshot survives the
  # restart that emptied ETS.
  defp rebuild_from_durable(%URI{} = orchestrator_uri) do
    with {:ok, session_uri, workspace_uri} <- resolve_session(orchestrator_uri),
         {:ok, chat_slice} <- load_chat_slice(session_uri),
         {:ok, wc} <- orchestrator_working_copy(chat_slice) do
      owner_uri = Map.get(chat_slice, :owner_uri)
      parent_template_uri = Map.get(wc, :session_template_uri)

      # Cache-fill the transport registry. The row still carries the full
      # session/workspace/owner/parent context (the readiness/register API
      # is unchanged); the transport only READS `session_uri` from it.
      _ =
        Ezagent.Orchestrator.McpRegistry.register(orchestrator_uri,
          session_uri: session_uri,
          workspace_uri: workspace_uri,
          owner_uri: owner_uri,
          parent_template_uri: parent_template_uri
        )

      new(orchestrator_uri: orchestrator_uri, session_uri: session_uri)
    else
      _ -> {:error, :orchestrator_not_registered}
    end
  end

  # Recover (session_uri, workspace_uri) from the orchestrator URI by
  # enumerating durable `session`-type snapshots in the workspace and
  # matching the one whose stored orchestrator URI equals the target.
  defp resolve_session(%URI{} = orchestrator_uri) do
    with %URI{} = workspace_uri <- workspace_of_orchestrator(orchestrator_uri),
         %URI{} = session_uri <- find_session_for_orchestrator(orchestrator_uri, workspace_uri) do
      {:ok, session_uri, workspace_uri}
    else
      _ -> :error
    end
  end

  defp workspace_of_orchestrator(%URI{} = orchestrator_uri) do
    case Ezagent.Capability.workspace_of(orchestrator_uri) do
      %URI{} = ws -> ws
      _ -> nil
    end
  end

  defp find_session_for_orchestrator(%URI{} = orchestrator_uri, %URI{} = workspace_uri) do
    target = URI.to_string(orchestrator_uri)

    Ezagent.Ecto.KindSnapshot.list_in_workspace(workspace_uri)
    |> Stream.filter(&(&1.kind_type == "session"))
    |> Stream.map(& &1.uri)
    |> Enum.find_value(fn uri_str ->
      with {:ok, session_uri} <- safe_parse(uri_str),
           %URI{} = stored <- stored_orchestrator_uri(session_uri),
           true <- URI.to_string(stored) == target do
        session_uri
      else
        _ -> nil
      end
    end)
  end

  defp safe_parse(uri_str) do
    {:ok, Ezagent.URI.new!(uri_str)}
  rescue
    _ -> :error
  end

  defp stored_orchestrator_uri(%URI{} = session_uri) do
    with {:ok, chat_slice} <- load_chat_slice(session_uri),
         {:ok, working_copy} <- orchestrator_working_copy(chat_slice),
         %URI{} = orchestrator_uri <- Map.get(working_copy, :orchestrator_uri) do
      orchestrator_uri
    else
      _ -> nil
    end
  end

  # Load the Session's durable `:chat` slice from its persisted snapshot,
  # routed through the canonical `Ezagent.Kind.normalize_slice_view/1`
  # chokepoint (handles the Lifecycle two-container shape).
  defp load_chat_slice(%URI{} = session_uri) do
    case Ezagent.Ecto.KindSnapshot.get(URI.to_string(session_uri)) do
      %Ezagent.Ecto.KindSnapshot{} = row ->
        case Ezagent.Ecto.KindSnapshot.decode_state(row) do
          {:ok, %{session: chat_slice}} when is_map(chat_slice) ->
            case Ezagent.Kind.normalize_slice_view(chat_slice) do
              normalized when is_map(normalized) -> {:ok, normalized}
              _ -> :error
            end

          _ ->
            :error
        end

      nil ->
        :error
    end
  end

  # A session HAS an orchestrator iff its durable working copy carries an
  # `:orchestrator_template_uri`. No orchestrator → fail-closed.
  defp orchestrator_working_copy(chat_slice) do
    wc = Map.get(chat_slice, :template_working_copy, %{})

    case Map.get(wc, :orchestrator_template_uri) do
      %URI{} -> {:ok, wc}
      _ -> :error
    end
  end

  defp fetch_uri(opts, key) do
    case Keyword.get(opts, key) do
      %URI{} = uri ->
        {:ok, uri}

      s when is_binary(s) ->
        try do
          {:ok, Ezagent.URI.new!(s)}
        rescue
          ArgumentError -> {:error, {:invalid_uri_opt, key, s}}
        end

      nil ->
        {:error, {:missing_opt, key}}

      other ->
        {:error, {:invalid_uri_opt, key, other}}
    end
  end

  @doc "The MCP `tools/list`-shaped descriptor for all orchestrator tools."
  @spec tool_schemas() :: [map()]
  defdelegate tool_schemas(), to: ToolCatalog

  @doc "The 9 tool names this MCP server exposes."
  @spec tool_names() :: [String.t()]
  defdelegate tool_names(), to: ToolCatalog

  # --- tools/call: decode → dispatch → encode (value form) ---------------

  @doc """
  Execute an MCP `tools/call` against the bound transport context.

  DECODES the `tool` name + `arguments`, FORWARDS via
  `Ezagent.Invocation.dispatch` to the session action
  `session://…?action=orchestrate.<tool>` carrying ONLY the orchestrator's
  caller URI (NO caps), and ENCODES the dispatched result to the MCP shape.

  Returns an MCP-shaped result map:

  - success — `%{"content" => [...], "structuredContent" => <result>,
    "isError" => false}`
  - tool error — `%{"isError" => true, "content" => [...],
    "error" => %{"code" => <atom-string>, "message" => <human text>}}`
  """
  @spec handle_tool_call(t(), String.t() | atom(), map()) :: map()
  def handle_tool_call(%__MODULE__{} = ctx, tool, arguments) when is_map(arguments) do
    case ToolRunner.normalize_tool(tool) do
      nil ->
        mcp_error(:unknown_tool, "Unknown tool: #{inspect(tool)}")

      tool_name ->
        ctx
        |> dispatch_tool(tool_name, arguments)
        |> to_mcp_result()
    end
  end

  def handle_tool_call(%__MODULE__{} = ctx, tool, _arguments) do
    handle_tool_call(ctx, tool, %{})
  end

  # Forward the decoded tools/call into the session domain. The dispatch
  # carries `ctx.caller = orchestrator_uri` and `ctx.caps = MapSet.new()` —
  # NO ambient / plugin-minted authority. The session action
  # (`Ezagent.Behavior.OrchestratorTools`) reconstructs the orchestrator's
  # delegated caps session-side and runs the op (O-4). Returns the raw
  # `{:ok, value}` / `{:error, reason}` the session action produced (the
  # action result), or a dispatch-level `{:error, _}` (transport failure).
  defp dispatch_tool(%__MODULE__{} = ctx, tool_name, arguments) do
    target = Ezagent.URI.with_action(ctx.session_uri, :orchestrate, tool_name)

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: target,
      mode: :call,
      args: %{arguments: arguments},
      ctx: %{
        caller: ctx.orchestrator_uri,
        # O-4 — NO authority crosses the plugin boundary. The session
        # action reconstructs the orchestrator's delegated caps.
        caps: MapSet.new(),
        reply: {:caller_inbox, self()}
      }
    })
  end

  # --- result mapping (transport encode) ---------------------------------

  # The session action returns its raw tool result AS the dispatch result
  # (`{:ok, {:ok, value}}` / `{:ok, {:error, reason}}`); a dispatch-level
  # failure (unroutable / not-ready / etc.) returns a bare `{:error, _}`.
  defp to_mcp_result({:ok, {:ok, value}}), do: success_result(value)
  defp to_mcp_result({:ok, {:error, reason}}), do: tool_error_result(reason)
  defp to_mcp_result({:ok, :ok}), do: success_result(:ok)
  defp to_mcp_result({:ok, other}), do: success_result(other)
  defp to_mcp_result(:ok), do: success_result(:ok)
  defp to_mcp_result({:error, reason}), do: tool_error_result(reason)
  defp to_mcp_result(other), do: success_result(other)

  defp success_result(value) do
    %{
      "content" => [%{"type" => "text", "text" => describe_success(value)}],
      "structuredContent" => stringify(value),
      "isError" => false
    }
  end

  defp tool_error_result(reason) do
    {code, message} = error_to_mcp(reason)
    mcp_error(code, message)
  end

  defp mcp_error(code, message) do
    %{
      "isError" => true,
      "content" => [%{"type" => "text", "text" => message}],
      "error" => %{"code" => to_string(code), "message" => message}
    }
  end

  # Map a tool / dispatch error reason to a structured MCP tool error.
  defp error_to_mcp(:unauthorized),
    do: {:unauthorized, "Not authorized — you lack the capability for this operation."}

  defp error_to_mcp(:cross_workspace_denied),
    do: {:cross_workspace_denied, "Denied — target is outside your workspace."}

  defp error_to_mcp(:parent_template_deleted),
    do:
      {:parent_template_deleted,
       "The parent template is gone — use save_template_as to persist under a new name."}

  defp error_to_mcp({:unknown_member_role, r}),
    do:
      {:unknown_member_role,
       "Rule receiver_role_name #{inspect(r)} is not a current session member's role_name — " <>
         "add the managed member (add_managed_member) first, or use a magic token."}

  defp error_to_mcp({:unknown_rule_receiver, r}),
    do:
      {:unknown_rule_receiver,
       "Rule receiver #{inspect(r)} is neither a current member role_name nor a " <>
         "valid URI — add the managed member (add_managed_member) first."}

  defp error_to_mcp({:source_template_missing_flavor, uri}),
    do:
      {:source_template_missing_flavor,
       "The source AgentTemplate #{URI.to_string(uri)} has no flavor — cannot spawn a member from it."}

  defp error_to_mcp({:role_name_taken, role_name}),
    do:
      {:role_name_taken,
       "role_name #{inspect(role_name)} is already held by another member in this session."}

  defp error_to_mcp({:missing_opt, key}),
    do: {:missing_context, "Missing orchestrator context: #{key}"}

  defp error_to_mcp({:missing_arg, key}),
    do: {:invalid_arguments, "Missing required argument: #{key}"}

  defp error_to_mcp({:invalid_arg, key}),
    do: {:invalid_arguments, "Invalid argument: #{key}"}

  defp error_to_mcp({:invalid_matcher, _}),
    do: {:invalid_matcher, "Invalid matcher — could not parse the routing matcher."}

  defp error_to_mcp(:hash_mismatch),
    do: {:hash_mismatch, "Template content hash mismatch — refusing to persist."}

  defp error_to_mcp(:immutable_version),
    do: {:immutable_version, "That template version already exists with different content."}

  defp error_to_mcp(:orchestrator_context_unavailable),
    do:
      {:orchestrator_context_unavailable,
       "Orchestrator session context could not be resolved — the session may not be live."}

  defp error_to_mcp(reason),
    do: {:tool_error, "Operation failed: #{inspect(reason)}"}

  defp describe_success(%URI{} = uri), do: "ok: #{URI.to_string(uri)}"
  defp describe_success(:already_removed), do: "ok: member already removed"
  defp describe_success(map) when is_map(map), do: "ok: #{inspect(stringify(map))}"
  defp describe_success(other), do: "ok: #{inspect(other)}"

  defp stringify(%URI{} = uri), do: URI.to_string(uri)
  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)

  defp stringify(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)
  end

  defp stringify(other), do: other

  # --- GenServer (process form) ------------------------------------------

  @doc """
  Start the orchestrator MCP transport as a process bound to one
  orchestrator agent. `opts` are the `new/1` opts plus an optional `:name`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, init_opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @doc "Execute a tool call against a running MCP-transport process."
  @spec tool_call(GenServer.server(), String.t() | atom(), map()) :: map()
  def tool_call(server, tool, arguments) do
    GenServer.call(server, {:tool_call, tool, arguments})
  end

  @doc "Return the bound context of a running MCP-transport process."
  @spec context(GenServer.server()) :: t()
  def context(server), do: GenServer.call(server, :context)

  @impl GenServer
  def init(opts) do
    case new(opts) do
      {:ok, ctx} -> {:ok, ctx}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:tool_call, tool, arguments}, _from, %__MODULE__{} = ctx) do
    args = if is_map(arguments), do: arguments, else: %{}
    {:reply, handle_tool_call(ctx, tool, args), ctx}
  end

  def handle_call(:context, _from, %__MODULE__{} = ctx) do
    {:reply, ctx, ctx}
  end
end
