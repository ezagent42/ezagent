defmodule EzagentWeb.WorldUploadsController do
  @moduledoc """
  Cap-authorized file-upload endpoint for the world composer (LV→world parity
  PR-2b).

  The world composer is a React island under `phx-update="ignore"`, so it cannot
  use the LiveView uploader (`live_file_input`/`consume_uploaded_entries`).
  Uploads arrive here over an HTTP `POST /world/uploads` (multipart) instead.

  ## One authorization path — through the dispatch chokepoint

  Authorization is NOT re-implemented here (the rejected first draft's mistake).
  The controller dispatches `:session :attach`, which the Kind runtime authorizes
  at the SAME chokepoint as `:session :send` (required `:attach` cap + provenance
  + workspace-isolation). `:attach` is co-granted with `:send` in the
  participation tier, so a member who may post a message may upload one — and
  nobody else. Reaching a successful dispatch means the caller is authorized; the
  controller then stores the bytes (filesystem I/O stays in this web request
  process, never the session actor), under the TARGET SESSION's workspace (so
  store-ws == download-ws by construction, mirroring `Admin.Compose`).

  ## Quarantine + delete-always (no orphans)

  The multipart entry is already a `Plug.Upload` temp file (the runtime's
  quarantine). On `:ok` it is `cp!`'d into the ws-partitioned uploads store and
  the temp file is left to Plug's normal request cleanup. On ANY failure the
  request returns without committing bytes. (`Uploads.store!/3` copies; the
  Plug.Upload temp is reaped by Plug after the request.)

  ## Anti-laundering grant

  The 200 response carries a signed `grant` binding `uri ↔ caller ↔ session`
  (`Phoenix.Token`, finite TTL). The composer sends grants — not raw URIs — on
  the next `chat.send`; `Ezagent.World.ConversationData.build_message/3` verifies
  each grant before embedding the bound URI, so a client cannot launder an
  arbitrary `resource://…/uploads/…` into a message. Same-caller/same-session
  replay is harmless (re-attaches the caller's own file) and accepted.
  """
  use EzagentWeb, :controller

  require Logger

  @grant_salt "world_attach"
  # 10 MB/file (matches the LV `max_file_size`); ≤ 5 files/message enforced at
  # send (`build_message/3`). The endpoint multipart parser `:length` bounds the
  # body before parse (the real DoS guard); this is the precise per-file check.
  @max_file_bytes 10 * 1024 * 1024

  @doc """
  Handle `POST /world/uploads`: dispatch `:session :attach` to authorize, store
  the file under the target session's workspace, and return the resource URI +
  a signed attach-grant. Errors map to 403 (unauthorized) / 413 (too large) /
  422 (bad params).
  """
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"session" => encoded, "file" => %Plug.Upload{} = upload})
      when is_binary(encoded) do
    caller = conn.assigns[:current_entity_uri]

    with {:ok, %URI{} = caller_uri} <- ensure_caller(caller),
         {:ok, %URI{} = session_uri} <- parse_session(encoded),
         :ok <- check_size(upload),
         {:ok, ws_name} <- session_workspace_name(session_uri),
         :ok <- authorize_attach(caller_uri, session_uri),
         {:ok, %URI{} = resource_uri} <- store(ws_name, upload) do
      grant = mint_grant(conn, resource_uri, caller_uri, session_uri)

      json(conn, %{
        "uri" => uri_string(resource_uri),
        "name" => display_name(upload),
        "size" => file_size(upload),
        "grant" => grant
      })
    else
      {:error, :unauthorized} ->
        conn |> put_status(:forbidden) |> json(%{"error" => "unauthorized"})

      {:error, :too_large} ->
        conn
        |> put_status(:request_entity_too_large)
        |> json(%{"error" => "file too large (max 10 MB)"})

      {:error, reason} ->
        Logger.debug(fn -> "WorldUploadsController: rejected upload: #{inspect(reason)}" end)
        conn |> put_status(:unprocessable_entity) |> json(%{"error" => "bad upload request"})
    end
  end

  def create(conn, _params) do
    conn |> put_status(:unprocessable_entity) |> json(%{"error" => "session + file required"})
  end

  # --- steps -------------------------------------------------------------

  defp ensure_caller(%URI{} = uri), do: {:ok, uri}
  defp ensure_caller(_), do: {:error, :unauthorized}

  defp parse_session(encoded) do
    with {:ok, decoded} <- {:ok, URI.decode_www_form(encoded)},
         {:ok, %URI{} = uri} <- Ezagent.URI.parse(decoded),
         true <- Ezagent.URI.scheme?(uri, :session) do
      {:ok, uri}
    else
      _ -> {:error, :bad_session}
    end
  end

  defp check_size(%Plug.Upload{} = upload) do
    if file_size(upload) > @max_file_bytes, do: {:error, :too_large}, else: :ok
  end

  defp session_workspace_name(session_uri) do
    case Ezagent.Capability.workspace_of(session_uri) do
      %URI{} = ws -> {:ok, Ezagent.URI.workspace_name!(ws)}
      _ -> {:error, :no_workspace}
    end
  end

  # The load-bearing check: dispatch `:session :attach`. The runtime authorizes
  # at the chokepoint from the caller's IDENTITY (the granted-via live-slice
  # path), so we pass EMPTY ctx caps — the controller never assembles or inspects
  # the caller's caps itself (enumerating caps caller-side is a p13 anti-pattern:
  # authority lives at the chokepoint, not in caller-side cap lists). Reaching
  # `:ok` means the caller holds the `:attach` cap.
  defp authorize_attach(caller_uri, session_uri) do
    target = Ezagent.URI.with_action(session_uri, :session, :attach)

    result =
      Ezagent.Invocation.dispatch(%Ezagent.Invocation{
        target: target,
        mode: :call,
        args: %{filename: "upload"},
        ctx: %{caller: caller_uri, caps: MapSet.new(), reply: :ignore},
        origin: :authenticated_external
      })

    case result do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp store(ws_name, %Plug.Upload{path: tmp_path} = upload) do
    {uri, _stored_name} = Ezagent.Uploads.store_upload!(ws_name, upload.filename, tmp_path)
    {:ok, uri}
  rescue
    e -> {:error, {:store_failed, Exception.message(e)}}
  end

  defp mint_grant(conn, %URI{} = resource_uri, %URI{} = caller_uri, %URI{} = session_uri) do
    Phoenix.Token.sign(conn, @grant_salt, %{
      "uri" => uri_string(resource_uri),
      "caller" => uri_string(caller_uri),
      "session" => uri_string(session_uri)
    })
  end

  # --- helpers (sanitize ported from Admin.Compose) ----------------------

  defp display_name(%Plug.Upload{filename: name}) when is_binary(name), do: name
  defp display_name(_), do: "file"

  defp file_size(%Plug.Upload{path: path}) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      _ -> 0
    end
  end

  defp uri_string(%URI{} = uri), do: URI.to_string(uri)
end
