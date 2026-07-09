defmodule EzagentWeb.UploadsController do
  @moduledoc """
  Serves chat-compose upload attachments (Resource-unification P2).

  ## 🔒 AUTH-CONTRACT CHANGE (P2 — Allen-gated)

  P2 replaces the participation-based authorization that the pre-P2 controller
  used (`caller_in_attaching_messages?/2` — admin / uploader / session-participant)
  with a **signed capability token** (OI-1 DECISION) + a ws-segment authority
  check, and a ws-partitioned on-disk layout (`…/uploads/<ws>/<name>`).

  The legacy `GET /files/:filename` route is **fully retired** (Allen-approved,
  2026-06-08) — no back-compat shim. Internal operator download links now mint
  the SAME signed token (`Ezagent.Uploads.DownloadToken`, a core module), so
  there is exactly one authorization carrier for every download surface.

  ### Internal route — `GET /uploads/download?token=<token>` (authenticated)

  This route is the **internal operator/session** download path — it sits under
  `RequireEntity`, so the caller is an authenticated Ezagent entity. The token
  (`Ezagent.Uploads.DownloadToken`) is a MAC-signed capability encoding the FULL
  ws-scoped `resource://<ws>/uploads/<name>` URI + a short TTL, minted only after
  the issuing surface authorized (the LiveView mint happens at render time, after
  the LiveView's in-workspace mount cap-check). On download the controller (a)
  verifies the token (MAC + finite TTL — NEVER `:infinity`), (b) extracts the
  bound URI, (c) runs the `FsResolver` `uploads` `authority/2` with the
  **request-mount workspace** (derived from the authenticated entity, NOT from
  the URI) so `uri.<ws> == mount.workspace`. A token bound to another workspace
  cannot be served to a foreign mount, and a token naming a non-uploads resource
  type is rejected by `Ezagent.Uploads`.

  ### External feed downloads live ELSEWHERE (codex P2 round-1 HIGH)

  The **external** feed (#601/#603, viewers reading as a minted anon/member) is
  served by the PUBLIC `GET /socialware/external/download` route on
  `EzagentWeb.Socialware.ExternalFeedController`, NOT this authenticated route —
  because a feed viewer would be bounced by `RequireEntity` here. That path
  authorizes by capability (the viewer's ChatFeedAuth session token + signed
  `DownloadToken`) and re-validates approved-only visibility at serve time via
  `Ezagent.Socialware.ExternalFeed.authorized_attachment_path/4`.

  ## No auth-widening — serve-time participant re-check (codex P2-revision HIGH)

  The signed token is a CONVENIENCE carrier (it names the file + bounds the
  leak window), NOT the sole authorization. Because the in-session LiveView
  renders a token link for everyone who can VIEW the session (workspace-level
  view authority, which includes observe-only callers without `chat.join`),
  minting alone would WIDEN access vs. the retired `/files` route — and a leaked
  token could be replayed by any same-workspace caller within its TTL. To keep
  the access decision from widening, `download/2` ALSO runs the independent
  participant authorization at serve time: the authenticated caller must be the
  **uploader** of an attaching message or a **session participant** (has sent a
  message into a session the attachment was routed to). A leaked/observer token
  is therefore useless to a non-participant. The pre-P2 contract's third
  disjunct — an admin bypass — was DELETED (admin/business decoupling,
  2026-07-09; `business_context_admin_checks` arch gate): attachments are
  business content, so admin authority here is membership, like any caller.

  ## Why the controller is thin

  Workspace isolation, traversal rejection (R-2), and the `Home.path` chokepoint
  (R-4) all live in `Ezagent.Resource.FsResolver` (via `Ezagent.Uploads`). The
  controller derives the authenticated mount workspace, verifies the token, runs
  the participant authz, resolves, serves. Authorization decisions happen BEFORE
  inspecting the disk so an unauthorized caller cannot use the 404/403
  distinction as a file-existence oracle.
  """

  use EzagentWeb, :controller

  import Ecto.Query

  alias Ezagent.{Message, MessageStore, Uploads}
  alias Ezagent.Uploads.DownloadToken
  alias Ezagent.URI, as: EzURI
  alias EzagentCore.Repo

  # Cap on the number of candidate Message rows we'll fully load + decode to
  # verify an attachment match (defense against a session that text-quoted the
  # filename many times). Exceeding it falls through to deny.
  @candidate_cap 256

  @doc """
  Primary download route — `GET /uploads/download?token=<token>`.

  Verifies the signed capability token, runs the participant authorization
  (uploader / session-participant — so the token does NOT widen access), then
  authorizes by ws-segment against the caller's authenticated mount workspace
  via the resolver's `authority/2`.
  """
  def download(conn, %{"token" => token}) when is_binary(token) do
    with {:ok, uri} <- DownloadToken.verify(token),
         caller_uri = conn.assigns[:current_entity_uri],
         {:ok, filename} <- EzURI.name(uri),
         true <- authorized?(caller_uri, filename),
         {:ok, mount_ws} <- mount_workspace(conn),
         {:ok, full} <- wrap_resolve(Uploads.resolve(uri, %{workspace: mount_ws})) do
      serve(conn, full, {:ok, filename})
    else
      _ -> forbidden(conn)
    end
  end

  def download(conn, _params), do: forbidden(conn)

  # --- Authorization (uploader / participant) ---------------------------------
  #
  # Membership governs — there is deliberately NO admin bypass (admin/business
  # decoupling, 2026-07-09; `business_context_admin_checks` arch gate): message
  # attachments are business content, so the genesis admin downloads exactly
  # what any caller does — files attached in sessions it participates in.

  # RequireEntity should have bounced an anon caller; defensive nil clause stays
  # false rather than crashing.
  defp authorized?(nil, _filename), do: false

  defp authorized?(%URI{} = caller_uri, filename) do
    caller_in_attaching_messages?(caller_uri, filename)
  end

  defp authorized?(_caller, _filename), do: false

  # Combined uploader + session-participant check. Loads candidate Message rows
  # (narrowed by SQL LIKE on body), decodes each row's `body.attachments` in
  # Elixir, and confirms the filename is in the ACTUAL attachment URI list —
  # NOT just substring-present in the body JSON.
  defp caller_in_attaching_messages?(%URI{} = caller_uri, filename) do
    candidates = load_candidate_messages(filename)
    attaching = Enum.filter(candidates, &message_attaches?(&1, filename))

    case attaching do
      [] ->
        false

      msgs ->
        caller_str = URI.to_string(caller_uri)

        uploader? = Enum.any?(msgs, fn m -> URI.to_string(m.sender) == caller_str end)

        if uploader? do
          true
        else
          attaching_session_uris =
            msgs
            |> Enum.flat_map(fn m -> MessageStore.sessions_for_message(m.id) end)
            |> Enum.uniq()

          caller_sent_in_any_session?(caller_str, attaching_session_uris)
        end
    end
  end

  defp load_candidate_messages(filename) do
    pattern = like_pattern(filename)
    escape = like_escape_char()

    from(m in Message,
      where:
        fragment(
          "CAST(? AS TEXT) LIKE ? ESCAPE ?",
          m.body,
          ^pattern,
          ^escape
        ),
      limit: @candidate_cap
    )
    |> Repo.all()
  end

  defp message_attaches?(%Message{body: body}, filename) do
    attachments =
      case body do
        %{attachments: list} when is_list(list) -> list
        %{"attachments" => list} when is_list(list) -> list
        _ -> []
      end

    Enum.any?(attachments, &attachment_matches?(&1, filename))
  end

  defp attachment_matches?(%URI{scheme: "resource"} = uri, filename) do
    EzURI.type?(uri, :uploads) and EzURI.name?(uri, filename)
  end

  defp attachment_matches?(s, filename) when is_binary(s) do
    attachment_matches?(EzURI.new!(s), filename)
  rescue
    ArgumentError -> false
  end

  defp attachment_matches?(_, _), do: false

  defp caller_sent_in_any_session?(_caller_str, []), do: false

  defp caller_sent_in_any_session?(caller_str, session_uris) when is_list(session_uris) do
    # Message session-scoping (2026-06-21): messages carry `session_uri` directly
    # (the `message_routings` join table was removed).
    from(m in Message,
      where: m.sender == ^caller_str and m.session_uri in ^session_uris,
      select: 1,
      limit: 1
    )
    |> Repo.exists?()
  end

  # SQL LIKE pattern matching the filename anywhere in CAST(body AS TEXT). We
  # escape `%`, `_`, `\` with `\` as the escape char (paired with an explicit
  # `ESCAPE '\'` in load_candidate_messages/1).
  defp like_pattern(filename) do
    escaped =
      filename
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

    "%" <> escaped <> "%"
  end

  defp like_escape_char, do: "\\"

  # --- internals -------------------------------------------------------------

  # The authenticated mount workspace — the AUTHORITATIVE subject. Derived from
  # the signed-in entity (NOT from the URI being resolved), so the ws-segment
  # authority check is non-tautological.
  #
  # The mount workspace is the SELECTED workspace (`:current_workspace_uri`
  # session slot), NOT the entity's home workspace — a system member can
  # context-switch (`WorkspaceSwitchController` / `SessionPrincipal`) into another
  # workspace while keeping `current_entity_uri` as `entity://.../system/…`.
  # Deriving from the entity (codex round-2 HIGH) would (a) deny a system member
  # the selected workspace's tokens and (b) still serve the entity's home-ws
  # files even when mounted elsewhere. Legacy sessions without the slot fall back
  # to the entity's home workspace (the pre-switcher invariant
  # `current_workspace_uri == entity_workspace_uri(current_entity_uri)`).
  defp mount_workspace(conn) do
    case get_session(conn, :current_workspace_uri) do
      ws_str when is_binary(ws_str) and ws_str != "" ->
        workspace_name_of(ws_str)

      _ ->
        entity_home_workspace(conn)
    end
  end

  defp workspace_name_of(ws_str) do
    with %URI{} = ws_uri <- EzURI.new!(ws_str),
         {:ok, name} <- EzURI.workspace_name(ws_uri) do
      {:ok, name}
    else
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp entity_home_workspace(conn) do
    with %URI{} = entity_uri <- conn.assigns[:current_entity_uri],
         %URI{} = ws_uri <- Ezagent.Capability.workspace_of(entity_uri),
         {:ok, name} <- EzURI.workspace_name(ws_uri) do
      {:ok, name}
    else
      _ -> :error
    end
  end

  # Normalize the resolver's tri-state into ok/error: a foreign-workspace
  # authority failure and a "not ours"/unsafe result both become `:error`
  # (uniform forbidden — no information leak).
  defp wrap_resolve({:ok, path}) when is_binary(path), do: {:ok, path}
  defp wrap_resolve(_), do: :error

  defp serve(conn, full, name_result) do
    if File.regular?(full) do
      send_download(conn, {:file, full}, filename: original_name(name_result))
    else
      conn
      |> put_status(:not_found)
      |> text("upload not found")
    end
  end

  defp forbidden(conn) do
    conn
    |> put_status(:forbidden)
    |> text("forbidden")
  end

  # Strip the `<uuid>-` prefix for the Content-Disposition download name.
  defp original_name({:ok, name}) when is_binary(name), do: original_name(name)
  defp original_name(:error), do: "download"
  defp original_name(<<_uuid::binary-size(36), "-", rest::binary>>), do: rest
  defp original_name(name) when is_binary(name), do: name
  defp original_name(_), do: "download"
end
