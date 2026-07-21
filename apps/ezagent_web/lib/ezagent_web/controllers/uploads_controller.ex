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

  ## Person-bound tokens (read-plane PR-3 — the grantee binding)

  A token minted with `grantee: <principal>` (read-plane PR-3 — e.g. the
  external-feed approved-only mint, or the kanban board's cap-gated artifact
  mint) is bound to the ONE principal the authorizing read issued it to. At
  serve time `caller == grantee` is the WHOLE authorization for a bound token —
  it REPLACES the legacy message-participation recheck below (the binding
  supersedes it: the mint itself was the authorization, and a leaked/copied
  token replayed by a non-grantee is rejected even when that principal would
  pass the legacy recheck). An **absent-grantee** (pre-PR-3) token carries no
  person binding and keeps the legacy recheck below unchanged — already-issued
  tokens neither break nor widen (zero-breakage).

  ## No auth-widening — serve-time participant re-check (codex P2-revision HIGH)

  For an UNBOUND (absent-grantee) token, the signed token is a CONVENIENCE
  carrier (it names the file + bounds the leak window), NOT the sole
  authorization. Because the in-session LiveView renders a token link for
  everyone who can VIEW the session (workspace-level view authority, which
  includes observe-only callers without `chat.join`), minting alone would WIDEN
  access vs. the retired `/files` route — and a leaked token could be replayed
  by any same-workspace caller within its TTL. To keep the access decision
  identical to the pre-P2 contract, `download/2` ALSO runs the independent
  participant authorization at serve time for an unbound token: the
  authenticated caller must be an **admin**, the **uploader** of an attaching
  message, or a **session participant** (has sent a message into a session the
  attachment was routed to). A leaked/observer token is therefore useless to a
  non-participant. A grantee-BOUND token gets the same no-widening guarantee
  from the person binding itself (only the authorized principal can use it).

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
  # filename many times). Exceeding it falls through to deny; admin bypass
  # remains the operator escape hatch.
  @candidate_cap 256

  @doc """
  Primary download route — `GET /uploads/download?token=<token>`.

  Verifies the signed capability token, then authorizes the serve: a
  grantee-BOUND token serves only its grantee (the PR-3 person binding, which
  supersedes the legacy recheck); an unbound (legacy) token runs the
  participant authorization (admin / uploader / session-participant — the
  pre-P2 contract, so an unbound token does NOT widen access). Finally the
  ws-segment authority check runs against the caller's authenticated mount
  workspace via the resolver's `authority/2`.
  """
  def download(conn, %{"token" => token}) when is_binary(token) do
    with {:ok, payload} <- DownloadToken.verify_payload(token),
         caller_uri = conn.assigns[:current_entity_uri],
         {:ok, filename} <- EzURI.name(payload.uri),
         true <- serve_authorized?(payload.grantee, caller_uri, filename),
         {:ok, mount_ws} <- mount_workspace(conn),
         {:ok, full} <- wrap_resolve(Uploads.resolve(payload.uri, %{workspace: mount_ws})) do
      serve(conn, full, {:ok, filename})
    else
      _ -> forbidden(conn)
    end
  end

  def download(conn, _params), do: forbidden(conn)

  # --- Serve authorization (PR-3 grantee binding / legacy recheck) ------------

  # Grantee-BOUND token (read-plane PR-3): the cap-gated mint authorized
  # `grantee` and bound the token to them, so `caller == grantee` is the whole
  # serve-time check — it SUPERSEDES the legacy participation recheck (this is
  # also what un-breaks the #9 kanban-403: a legit member holding a token the
  # board minted FOR them downloads without needing message participation).
  defp serve_authorized?(%URI{} = grantee, caller_uri, _filename),
    do: DownloadToken.grantee_match?(grantee, caller_uri)

  # Absent-grantee (pre-PR-3) token: the legacy participant recheck still
  # applies (admin / uploader / session-participant — zero breakage, no
  # widening for already-issued tokens).
  defp serve_authorized?(nil, caller_uri, filename),
    do: authorized?(caller_uri, filename)

  # --- Legacy authorization (pre-P2 contract — admin / uploader / participant) --

  # RequireEntity should have bounced an anon caller; defensive nil clause stays
  # false rather than crashing.
  defp authorized?(nil, _filename), do: false

  defp authorized?(%URI{} = caller_uri, filename) do
    cond do
      admin?(caller_uri) -> true
      caller_in_attaching_messages?(caller_uri, filename) -> true
      true -> false
    end
  end

  defp authorized?(_caller, _filename), do: false

  defp admin?(%URI{} = uri) do
    if Code.ensure_loaded?(Ezagent.Identity) and
         function_exported?(Ezagent.Identity, :admin?, 1) do
      Ezagent.Identity.admin?(uri)
    else
      false
    end
  end

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

          caller_member_of_any_session?(caller_uri, attaching_session_uris)
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

  defp caller_member_of_any_session?(_caller, []), do: false

  defp caller_member_of_any_session?(%URI{} = caller, session_uris) when is_list(session_uris) do
    Enum.any?(session_uris, fn
      %URI{} = session_uri ->
        Ezagent.Socialware.SessionReads.authorized?(caller, session_uri)

      session_uri when is_binary(session_uri) ->
        session_uri
        |> EzURI.new!()
        |> then(&Ezagent.Socialware.SessionReads.authorized?(caller, &1))

      _ ->
        false
    end)
  rescue
    _ -> false
  end

  defp caller_member_of_any_session?(_caller, _sessions), do: false

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
