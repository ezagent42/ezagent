defmodule EzagentWeb.UploadsController do
  @moduledoc """
  Serves files uploaded via the chat compose UI (PR-B).

  Files live under `$EZAGENT_HOME/<profile>/uploads/` and are named
  `<uuid>-<original-name>`. The controller takes only the filename
  segment from the URL — directory traversal (`..`) is blocked via
  `Path.basename/1` sanitization here.

  ## Routing

  Mounted at `GET /files/:filename` inside the `RequireEntity`
  pipeline (so any caller has a signed-in entity in
  `conn.assigns.current_entity_uri`). The pre-2026-05-25 path was
  `/admin/uploads/:filename`, which sat under the `/admin/*` URL
  prefix and gave the false impression of being admin-gated by the
  `live_session :require_admin` block; it wasn't, because
  `live_session` only gates LiveView mounts (codex PR #305 r4 HIGH).

  ## Authorization

  RequireEntity only proves "some signed-in entity"; it does NOT
  prove a relationship to the requested file. Without an explicit
  check, any signed-in user who could guess (or brute-force) a
  filename — `<uuid>-<original-name>` — would receive ANOTHER
  user's upload. The fix enforces per-user authz here:

  1. **Admin bypass** — `Ezagent.Identity.admin?(current_entity_uri)`
     allows ops/debugging access to any upload.

  2. **Uploader** — the caller is the `sender` of any persisted
     `Ezagent.Message` whose **decoded** `body.attachments` list
     contains a `resource://uploads/<workspace>/<filename>` URI for
     the requested filename. Authoritative match — we materialize
     the Message rows (Ecto decodes `body` from JSON) and compare
     the attachment URI list in Elixir. A SQL `LIKE` is used ONLY
     to narrow the candidate set; it is NOT sufficient on its own
     (codex 2026-05-25 r1 HIGH — a `LIKE` over the whole body JSON
     would let an attacker self-authorize by sending text that
     mentions the filename).

  3. **Session participant** — the caller is the `sender` of any
     persisted message routed to a session that ALSO contains a
     message whose **decoded** attachments include the file's
     resource URI. Persistent proxy for "session member with
     read-cap": you can only have sent a message in a session if
     you were a member (slice membership gates `:send`), and
     chat-cap-granted members effectively see all attachments in
     that session.

     **Known limitation** (codex r1 MED, accepted for v1): this is
     historical, not current. A removed user or revoked-cap user
     who has filename foreknowledge could still fetch a future
     attachment in a session they used to participate in. A
     stricter "current session read-cap" check is tracked as a
     follow-up; for v1 the bar is "cross-user filename guessing
     yields 403," which this check satisfies.

  All other callers — including signed-in users who simply guess
  filenames — get `403 Forbidden`. The authz decision is computed
  BEFORE inspecting the filesystem so a non-authorized caller
  cannot use the `404 not found` / `403 forbidden` distinction as
  a filename-existence oracle (codex r1 LOW): unauthorized always
  yields the same response regardless of disk presence.

  Filename validation (basename, reject empty / `.` / `..`) still
  runs first so an attacker can't use path traversal to read
  outside the uploads dir.

  See `docs/futures/todo.md` for the gating TODO this controller
  closes; the regression test
  (`apps/ezagent_web/test/ezagent_web/controllers/uploads_controller_test.exs`)
  pins the cross-user-isolation invariants.
  """

  use EzagentWeb, :controller

  import Ecto.Query

  alias Ezagent.{Home, Message, MessageRouting, MessageStore}
  alias EzagentCore.Repo

  # Cap on the number of candidate Message rows we'll fully load +
  # decode to verify an attachment match. Messages with the filename
  # appearing literally anywhere in `body` (after SQL LIKE narrowing)
  # are rare in practice; this bound is just defense against
  # pathological cases (e.g., a chatty session that text-quoted the
  # filename N times). If we ever exceed it, the participant check
  # falls through to deny — admin bypass remains the operator
  # escape hatch.
  @candidate_cap 256

  def show(conn, %{"filename" => filename}) do
    safe = Path.basename(filename)

    cond do
      safe == "" or safe == "." or safe == ".." or safe != filename ->
        conn
        |> put_status(:bad_request)
        |> text("invalid filename")

      true ->
        caller_uri = conn.assigns[:current_entity_uri]

        # Authorize BEFORE looking at the disk so the response can't
        # leak file existence to an unauthorized caller (codex r1 LOW).
        if authorized?(caller_uri, safe) do
          full = Path.join(Home.path("uploads"), safe)

          if File.regular?(full) do
            send_download(conn, {:file, full}, filename: original_name(safe))
          else
            conn
            |> put_status(:not_found)
            |> text("upload not found")
          end
        else
          conn
          |> put_status(:forbidden)
          |> text("forbidden")
        end
    end
  end

  # --- Authorization ---------------------------------------------------------

  # RequireEntity should have bounced an anon caller before we reach
  # here; defensive `nil` clause stays false rather than crashing.
  defp authorized?(nil, _filename), do: false

  defp authorized?(%URI{} = caller_uri, filename) do
    cond do
      admin?(caller_uri) -> true
      caller_in_attaching_messages?(caller_uri, filename) -> true
      true -> false
    end
  end

  defp admin?(%URI{} = uri) do
    # Defensive guard for boot-time / test environments where
    # `Ezagent.Identity` may not be loaded yet. Mirrors the pattern
    # in `EzagentWeb.LiveAuth.admin?/1`.
    if Code.ensure_loaded?(Ezagent.Identity) and
         function_exported?(Ezagent.Identity, :admin?, 1) do
      Ezagent.Identity.admin?(uri)
    else
      false
    end
  end

  # Combined uploader + session-participant check. Loads candidate
  # Message rows (narrowed by SQL LIKE on body), decodes each row's
  # `body.attachments` in Elixir, and confirms the filename is in
  # the ACTUAL attachment URI list — NOT just substring-present in
  # the body JSON (codex r1 HIGH — that would let `body.text`
  # text-content match).
  defp caller_in_attaching_messages?(%URI{} = caller_uri, filename) do
    candidates = load_candidate_messages(filename)

    # Step 1: messages that genuinely attach `filename`.
    attaching = Enum.filter(candidates, &message_attaches?(&1, filename))

    case attaching do
      [] ->
        false

      msgs ->
        caller_str = URI.to_string(caller_uri)

        # Uploader branch: caller sent any of those attaching messages.
        uploader? =
          Enum.any?(msgs, fn m -> URI.to_string(m.sender) == caller_str end)

        if uploader? do
          true
        else
          # Session-participant branch: caller has sent at least one
          # message routed to any session that any attaching message
          # was routed to. `MessageStore.sessions_for_message/1`
          # returns `[String.t()]`.
          attaching_session_uris =
            msgs
            |> Enum.flat_map(fn m -> MessageStore.sessions_for_message(m.id) end)
            |> Enum.uniq()

          caller_sent_in_any_session?(caller_str, attaching_session_uris)
        end
    end
  end

  # Pull at most @candidate_cap message rows whose body JSON contains
  # the filename substring (uses SQL LIKE for index-free SQLite scan +
  # ESCAPE so `%`, `_`, `\` in filenames don't act as wildcards). The
  # SQL match is intentionally LOOSE — false positives are filtered out
  # in `message_attaches?/2` by inspecting the decoded attachments list.
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

  # Authoritative match: the resource URI for this filename must be in
  # the decoded `body.attachments` list. Tolerates either string OR
  # `%URI{}` items (body is a `:map` field stored as raw JSON; on
  # decode, attachments come back as strings — though tests build
  # them as URI structs in-memory).
  defp message_attaches?(%Message{body: body}, filename) do
    attachments =
      case body do
        %{attachments: list} when is_list(list) -> list
        %{"attachments" => list} when is_list(list) -> list
        _ -> []
      end

    Enum.any?(attachments, &attachment_matches?(&1, filename))
  end

  # Resource URI shape: `resource://uploads/<workspace>/<filename>`.
  # Match the host + last path segment exactly.
  defp attachment_matches?(%URI{scheme: "resource", host: "uploads", path: "/" <> rest}, filename) do
    Path.basename(rest) == filename
  end

  defp attachment_matches?(s, filename) when is_binary(s) do
    # SPEC 2026-05-27-uri-canonicalization §3.3 — canonical chokepoint
    # with try/rescue keeping the boolean-return contract; malformed
    # mention URIs simply don't match.
    try do
      attachment_matches?(Ezagent.URI.parse!(s), filename)
    rescue
      ArgumentError -> false
    end
  end

  defp attachment_matches?(_, _), do: false

  defp caller_sent_in_any_session?(_caller_str, []), do: false

  defp caller_sent_in_any_session?(caller_str, session_uris) when is_list(session_uris) do
    from(m in Message,
      join: r in MessageRouting,
      on: r.message_id == m.id,
      where: m.sender == ^caller_str and r.session_uri in ^session_uris,
      select: 1,
      limit: 1
    )
    |> Repo.exists?()
  end

  # SQL LIKE pattern that matches the filename anywhere in the
  # CAST(body AS TEXT) representation. We escape `%`, `_`, and `\`
  # using `\` as the escape character (SQLite doesn't default to one);
  # the caller pairs this with an explicit `ESCAPE '\'` clause in
  # `load_candidate_messages/1` — see codex r1 MED.
  defp like_pattern(filename) do
    escaped =
      filename
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

    "%" <> escaped <> "%"
  end

  defp like_escape_char, do: "\\"

  defp original_name(<<_uuid::binary-size(36), "-", rest::binary>>), do: rest
  defp original_name(other), do: other
end
