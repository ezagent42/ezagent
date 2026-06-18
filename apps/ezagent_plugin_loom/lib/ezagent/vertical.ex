defmodule Ezagent.PluginLoom.Vertical do
  @moduledoc """
  Glue for running loom as a socialware vertical from the existing loom_ui SPA
  (F1 shim). The SPA is message-driven: it reads the page from the latest
  `<span type="page_update">{files,…}</span>` message (`/pages`), the chat from
  `/history`, and re-renders Sandpack on `page_update` frames over `/stream`.

  So this module:

  - `ensure_session/3` — spawn the UNIFIED `Entity.Session` with the socialware
    behavior subset (Turn/Surface active) + working-copy + operator (P0 path,
    shared with `Template.LoomVerticalSession`);
  - `seed_page/3` — put the initial page into Surface + emit the seed
    `page_update` message so the SPA renders on first open;
  - `author/3` — the SPA's "send" on the substrate: record the user message,
    generate the page (`PageGen`), land it in Surface via `TurnManager`
    (→ customer delivery), and emit a `page_update` message so loom_ui renders.

  The page therefore lives in **Surface** (substrate truth, consumer reads it via
  `CustomerFeed`) AND is mirrored as a `page_update` message (the loom_ui editor
  channel). See `docs/loom-port/SOCIALWARE-VERTICAL.md`.
  """

  require Logger

  alias Ezagent.Entity.Session
  alias Ezagent.{Invocation, KindRegistry, SystemPrincipal, WorkspaceRegistry}
  # NOTE: loom has two namespaces — the new vertical modules are
  # `Ezagent.PluginLoom.*`, but loom's existing helpers are `EzagentPluginLoom.*`.
  alias Ezagent.PluginLoom.{PageGen, TurnManager}
  alias EzagentPluginLoom.{Prompts, Span}

  @doc "Spawn the unified SocialwareSession for a loom vertical (idempotent)."
  @spec ensure_session(String.t(), String.t(), URI.t() | nil) :: {:ok, URI.t()} | {:error, term()}
  def ensure_session(ws, sid, operator_uri \\ nil) when is_binary(ws) and is_binary(sid) do
    session_uri = session_uri(ws, sid)
    workspace_uri = Ezagent.URI.new!("workspace://#{ws}")

    spawn_result =
      case Ezagent.Kind.spawn(Session, %{uri: session_uri, behaviors: Session.socialware_behaviors()}) do
        {:ok, _} -> :fresh
        {:error, {:already_started, _}} -> :existing
        {:error, reason} -> {:error, reason}
      end

    case spawn_result do
      {:error, _} = err ->
        err

      _fresh_or_existing ->
        _ = WorkspaceRegistry.bind(session_uri, workspace_uri)

        _ =
          Ezagent.Behavior.Session.system_set_working_copy(session_uri, %{
            "class" => "session.loom",
            "vertical" => "loom",
            "session_name" => sid,
            "operator_uri" => operator_uri |> uri_str()
          })

        _ = maybe_join_operator(session_uri, operator_uri)

        # 2026-06-18 — restore the multi-agent team as members of the vertical
        # SocialwareSession (orchestrator + workers + builder + meta + salesperson).
        # They keep their @-mention interactions; the builder's page lands in
        # Surface via `LoomOrchestrator.handle_page_update` (→ CustomerFeed). This
        # is the substrate-native team: member agents on the unified session.
        _ = EzagentPluginLoom.Team.ensure_team(session_uri)

        {:ok, session_uri}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc "Seed the initial page (Surface version + page_update message) if the session has no page yet."
  @spec seed_page(String.t(), String.t(), map() | nil) :: :ok
  def seed_page(ws, sid, files \\ nil) do
    session_uri = session_uri(ws, sid)
    files = normalize_files(files)

    if current_files(session_uri) in [nil, %{}] do
      manager = manager_uri(session_uri)
      _ = TurnManager.build_page(session_uri, manager, "__seed__", fn _ -> {:ok, %{tree: files, reply: ""}} end)
      _ = emit_page_update(session_uri, manager, files, "初始页")
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  The SPA "send" on the substrate. `sender_uri` is the resolved caller (a user).
  Records the user message, generates/edits the page, lands it in Surface via a
  turn, and emits the `page_update` message the SPA renders.
  """
  @spec author(URI.t(), URI.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def author(%URI{} = session_uri, %URI{} = sender_uri, request) when is_binary(request) do
    {ws, sid} = ws_sid(session_uri)
    mentions = route_mentions(request, ws, sid)
    msg = emit_message(session_uri, sender_uri, %{text: request, attachments: []}, mentions)
    _ = maybe_emit_builder_ack(session_uri, ws, sid, mentions)
    {:ok, %{ok: true, id: msg.id}}
  end

  # 2026-06-18 — 出页要等 builder 调 LLM(十几秒),期间用户干等不知状态。@builder 一发,
  # 立刻以 **builder 身份**冒一条状态消息——经现有 SSE `/stream` 实时推到聊天,用户秒级知道
  # "收到 + 在生成"。纯状态:`ref_id: nil` / `mentions: []` / 无 page_update span,所以编排器
  # 不会把它当页面或 deliverable 处理(只是一条可见气泡)。完成时真页面(page_update)再跟上。
  defp maybe_emit_builder_ack(session_uri, ws, sid, mentions) do
    builder = agent_uri(ws, "loombuilder_#{sid}")

    if builder in mentions do
      body = %{
        text: "🔨 builder 已收到需求,正在生成页面…(通常十几秒,完成后预览会自动更新)",
        attachments: []
      }

      emit_message(session_uri, builder, body, [])
    end
  end

  # Route by the leading @-mention. `@builder`/`@loombuilder_<sid>` → builder (the
  # page path); `@meta`/`@loommeta_<sid>` → meta; `@worker_<theme>`/
  # `@loomworker_<sid>_<theme>` → that worker. NO @ → no mention: the message is
  # just an ordinary session utterance, NOT a page build (only @builder builds).
  defp route_mentions(text, ws, sid) do
    t = text |> to_string() |> String.trim_leading()

    cond do
      Regex.match?(~r/^@(loombuilder_#{sid}|builder|v0)\b/i, t) ->
        [agent_uri(ws, "loombuilder_#{sid}")]

      Regex.match?(~r/^@(loommeta_#{sid}|meta)\b/i, t) ->
        [agent_uri(ws, "loommeta_#{sid}")]

      match = Regex.run(~r/^@loomworker_#{sid}_([a-z0-9_]+)/i, t) ->
        [agent_uri(ws, "loomworker_#{sid}_#{Enum.at(match, 1)}")]

      match = Regex.run(~r/^@worker[_\s]+([a-z0-9_]+)/i, t) ->
        [agent_uri(ws, "loomworker_#{sid}_#{Enum.at(match, 1)}")]

      true ->
        []
    end
  end

  defp agent_uri(ws, name), do: Ezagent.URI.new!("entity://#{ws}/agent/#{name}")

  defp ws_sid(%URI{host: ws, path: "/" <> rest}) do
    sid = rest |> String.split("/") |> List.last()
    {ws, sid}
  end

  # ── reads ──

  @doc "Current page files map: latest page_update message, else the Surface tree, else nil."
  @spec current_files(URI.t()) :: map() | nil
  def current_files(%URI{} = session_uri) do
    case latest_page_update_files(session_uri) do
      files when is_map(files) and map_size(files) > 0 -> files
      _ -> surface_tree(session_uri)
    end
  end

  defp latest_page_update_files(session_uri) do
    session_uri
    |> Ezagent.MessageStore.recent_in_session(50)
    |> Enum.find_value(fn m -> m.body |> body_text() |> page_update_files() end)
  rescue
    _ -> nil
  end

  # Parse the files map out of a `<span type="page_update">{…}</span>` message
  # body (the loom_ui editor channel). `files` map preferred, `source` string
  # (App.jsx) as fallback.
  defp page_update_files(text) when is_binary(text) do
    case Regex.run(~r/<span type="page_update">(\{.*\})<\/span>/s, text) do
      [_, json] ->
        case Jason.decode(json) do
          {:ok, %{"files" => f}} when is_map(f) and map_size(f) > 0 -> f
          {:ok, %{"source" => s}} when is_binary(s) and s != "" -> %{"/App.jsx" => s}
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp page_update_files(_), do: nil

  defp surface_tree(session_uri) do
    case Ezagent.Kind.get_slice(session_uri, :surface) do
      {:ok, %{versions: versions, version_seq: seq}} when is_integer(seq) and seq > 0 ->
        case Map.get(versions, seq) do
          %{tree: tree} -> tree
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  # ── writes ──

  defp emit_page_update(session_uri, sender_uri, files, summary) do
    span_map = %{
      "files" => files,
      "source" => Map.get(files, "/App.jsx", ""),
      "summary" => summary
    }

    body_text = Span.span("page_update", span_map)
    emit_message(session_uri, sender_uri, %{text: body_text, attachments: []}, [])
  end

  defp emit_message(session_uri, sender_uri, body, mentions) do
    msg = Ezagent.Message.new(sender_uri, body, mentions: mentions)

    _ =
      Invocation.dispatch(%Invocation{
        target: Ezagent.URI.with_action(session_uri, :session, :send),
        mode: :cast,
        args: %{message: msg},
        ctx: %{
          caller: sender_uri,
          caps: SystemPrincipal.caps("system://session-internal"),
          reply: :ignore
        }
      })

    msg
  end

  # ── helpers ──

  defp session_uri(ws, sid), do: Ezagent.URI.new!("session://#{ws}/loom/#{sid}")

  # The manager/orchestrator that drives turns: a synthetic per-session agent
  # URI (TurnManager constructs the within-session cap, so it need not be a live
  # Kind). Page_update messages sent from it render as an AI bubble (role=agent).
  defp manager_uri(%URI{host: ws, path: "/" <> rest}) do
    sid = rest |> String.split("/") |> List.last()
    Ezagent.URI.new!("entity://#{ws}/agent/loommgr_#{sid}")
  end

  defp maybe_join_operator(_session_uri, nil), do: :ok

  defp maybe_join_operator(session_uri, %URI{} = operator_uri) do
    _ = ensure_user(operator_uri)

    Invocation.dispatch(%Invocation{
      target: Ezagent.URI.with_action(session_uri, :session, :join),
      mode: :call,
      args: %{member: operator_uri, role_name: "operator", in_session_template: true},
      ctx: %{
        caller: SystemPrincipal.uri("template-materialize"),
        caps: "template-materialize" |> SystemPrincipal.uri() |> SystemPrincipal.caps(),
        reply: {:caller_inbox, self()}
      }
    })
  rescue
    _ -> :error
  end

  defp ensure_user(%URI{} = user_uri) do
    case KindRegistry.lookup(user_uri) do
      {:ok, _} -> :ok
      :error ->
        _ = Ezagent.Users.create(user_uri, nil, [])
        _ = Ezagent.SpawnRegistry.spawn(user_uri)
        :ok
    end
  rescue
    _ -> :ok
  end

  defp normalize_files(nil), do: Prompts.loom_seed_files()
  defp normalize_files(files) when is_map(files) and map_size(files) > 0, do: files
  defp normalize_files(_), do: Prompts.loom_seed_files()

  defp uri_str(nil), do: ""
  defp uri_str(%URI{} = u), do: URI.to_string(u)
  defp uri_str(s) when is_binary(s), do: s

  defp body_text(%{text: t}) when is_binary(t), do: t
  defp body_text(%{"text" => t}) when is_binary(t), do: t
  defp body_text(_), do: nil

  defp msg_id(%Ezagent.Message{id: id}), do: id
  defp msg_id(_), do: nil
end
