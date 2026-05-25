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
     `Ezagent.Message` whose `body.attachments` references this
     filename.

  3. **Session participant** — the caller is the `sender` of any
     persisted message routed to a session that ALSO contains a
     message attaching this filename. This is a defensible
     persistent proxy for "session member with read-cap": you can
     only have sent a message in a session if you were a member
     (slice membership gates `:send`), and chat-cap-granted
     members effectively see all attachments in that session.
     (A member who joined but never sent is an edge case; admins
     can fall back to bypass #1, and they can grant explicit
     `Behavior.Identity` access if needed.)

  All other callers — including signed-in users who simply guess
  filenames — get `403 Forbidden`. Filename validation (basename,
  reject empty / `.` / `..`) still runs first so an attacker can't
  use path traversal to read outside the uploads dir.

  See `docs/futures/todo.md` for the gating TODO this controller
  closes; the regression test
  (`apps/ezagent_web/test/ezagent_web/controllers/uploads_controller_test.exs`)
  pins the cross-user-isolation invariant.
  """

  use EzagentWeb, :controller

  import Ecto.Query

  alias Ezagent.{Home, Message, MessageRouting}
  alias EzagentCore.Repo

  def show(conn, %{"filename" => filename}) do
    safe = Path.basename(filename)

    cond do
      safe == "" or safe == "." or safe == ".." or safe != filename ->
        conn
        |> put_status(:bad_request)
        |> text("invalid filename")

      true ->
        full = Path.join(Home.path("uploads"), safe)
        caller_uri = conn.assigns[:current_entity_uri]

        cond do
          not File.regular?(full) ->
            conn
            |> put_status(:not_found)
            |> text("upload not found")

          authorized?(caller_uri, safe) ->
            send_download(conn, {:file, full}, filename: original_name(safe))

          true ->
            # Deny-by-default. 403 (not 404) so a legitimate uploader
            # who hits a transient DB hiccup gets a deterministic
            # signal rather than a misleading "missing" message.
            conn
            |> put_status(:forbidden)
            |> text("forbidden")
        end
    end
  end

  # --- Authorization helpers -------------------------------------------------

  # Hook for the SessionPrincipal-less path. RequireEntity already
  # bounced an anon caller, so reaching here without a URI is an
  # invariant violation — let-it-crash.
  defp authorized?(nil, _filename), do: false

  defp authorized?(%URI{} = caller_uri, filename) do
    cond do
      admin?(caller_uri) -> true
      uploader?(caller_uri, filename) -> true
      session_participant?(caller_uri, filename) -> true
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

  # True iff there exists a persisted Message whose sender == caller
  # AND body.attachments references `filename`.
  defp uploader?(%URI{} = caller_uri, filename) when is_binary(filename) do
    pattern = attachment_like_pattern(filename)
    caller_str = URI.to_string(caller_uri)

    query =
      from(m in Message,
        where:
          m.sender == ^caller_str and
            like(fragment("CAST(? AS TEXT)", m.body), ^pattern),
        select: 1,
        limit: 1
      )

    Repo.exists?(query)
  end

  # True iff caller has sent ≥1 message in some session_uri that ALSO
  # contains a routing for a message attaching `filename`. Two-query
  # form (rather than a single JOIN) so we can keep the body LIKE
  # search on a small candidate set.
  defp session_participant?(%URI{} = caller_uri, filename) when is_binary(filename) do
    pattern = attachment_like_pattern(filename)
    caller_str = URI.to_string(caller_uri)

    # Step 1: sessions that contain a message attaching this file.
    attaching_session_uris =
      from(m in Message,
        join: r in MessageRouting,
        on: r.message_id == m.id,
        where: like(fragment("CAST(? AS TEXT)", m.body), ^pattern),
        select: r.session_uri,
        distinct: true
      )
      |> Repo.all()

    case attaching_session_uris do
      [] ->
        false

      sessions ->
        # Step 2: has caller sent any message routed to one of those sessions?
        from(m in Message,
          join: r in MessageRouting,
          on: r.message_id == m.id,
          where: m.sender == ^caller_str and r.session_uri in ^sessions,
          select: 1,
          limit: 1
        )
        |> Repo.exists?()
    end
  end

  # Build a SQL LIKE pattern that matches an attachment URI ending
  # in `/<filename>`. Resource URIs are `resource://uploads/<workspace>/<filename>`,
  # so the trailing `/<filename>"` (with the JSON-quote-close) is a
  # tight pin against the body JSON.
  #
  # Filenames are `<36-char-uuid>-<original>`, sanitized at upload
  # time via `sanitize_filename/1` in AdminLive — no `%`, `_`, or `\`
  # injection surface. Defense-in-depth: we still escape the SQL
  # LIKE wildcards in case sanitize_filename's allowlist ever loosens.
  defp attachment_like_pattern(filename) do
    escaped =
      filename
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

    "%/" <> escaped <> "\"%"
  end

  defp original_name(<<_uuid::binary-size(36), "-", rest::binary>>), do: rest
  defp original_name(other), do: other
end
