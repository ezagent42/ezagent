defmodule EzagentWeb.UploadsController do
  @moduledoc """
  Serves chat-compose upload attachments (Resource-unification P2).

  ## 🔒 AUTH-CONTRACT CHANGE (P2 — Allen-gated)

  P2 replaces the participation-based authorization that the pre-P2 controller
  used (`caller_in_attaching_messages?/2` — admin / uploader / session-participant)
  with a **signed capability token** (OI-1 DECISION) + a ws-segment authority
  check, and a ws-partitioned on-disk layout (`…/uploads/<ws>/<name>`).

  ### Internal route — `GET /uploads/download?token=<token>` (authenticated)

  This route is the **internal operator/session** download path — it sits under
  `RequireEntity`, so the caller is an authenticated Ezagent entity. The token
  (`EzagentWeb.Uploads.UploadToken`) is a MAC-signed capability encoding the FULL
  ws-scoped `resource://<ws>/uploads/<name>` URI + a short TTL, minted only after
  the issuing surface authorized (the LiveView mount is a live in-workspace
  session). On download the controller (a) verifies the token (MAC + finite TTL —
  NEVER `:infinity`), (b) extracts the bound URI, (c) runs the `FsResolver`
  `uploads` `authority/2` with the **request-mount workspace** (derived from the
  authenticated entity, NOT from the URI) so `uri.<ws> == mount.workspace`. A
  token bound to another workspace cannot be served to a foreign mount, and a
  token naming a non-uploads resource type is rejected by `Ezagent.Uploads`.

  ### External customer-feed downloads live ELSEWHERE (codex P2 round-1 HIGH)

  The **external** customer-feed (#601/#603, viewers with NO session/caps) is
  served by the PUBLIC `GET /socialware/customer/download` route on
  `EzagentWeb.Socialware.CustomerController`, NOT this authenticated route —
  because a feed viewer would be bounced by `RequireEntity` here. That path
  authorizes purely by capability (customer-feed session token + signed
  `UploadToken`) and re-validates approved-only visibility at serve time via
  `Ezagent.Socialware.CustomerFeed.authorized_attachment_path/4`.

  ### Back-compat shim — `GET /files/:filename` (the ONE sanctioned shim, N6)

  Already-minted filename-only links keep working during a stated deprecation
  window. With no `<ws>` in the URL, the shim resolves the filename under the
  caller's authenticated **mount workspace** — it serves the caller's OWN
  workspace copy. This is the disambiguation the new contract makes explicit;
  today's filenames are UUID-prefixed so a cross-workspace filename collision is
  effectively impossible. Remove this route + its handling when the window closes.

  ## Why the controller is now thin

  Workspace isolation, traversal rejection (R-2), and the `Home.path` chokepoint
  (R-4) all live in `Ezagent.Resource.FsResolver` (via `Ezagent.Uploads`). The
  controller is a transport adapter: derive the authenticated mount workspace,
  resolve, serve. Authorization decisions happen BEFORE inspecting the disk so an
  unauthorized caller cannot use the 404/403 distinction as a file-existence
  oracle.
  """

  use EzagentWeb, :controller

  alias Ezagent.Uploads
  alias Ezagent.URI, as: EzURI
  alias EzagentWeb.Uploads.UploadToken

  @doc """
  Primary download route — `GET /uploads/download?token=<token>`.

  Verifies the signed capability token, then authorizes by ws-segment against the
  caller's authenticated mount workspace via the resolver's `authority/2`.
  """
  def download(conn, %{"token" => token}) when is_binary(token) do
    with {:ok, uri} <- UploadToken.verify(token),
         {:ok, mount_ws} <- mount_workspace(conn),
         {:ok, full} <- wrap_resolve(Uploads.resolve(uri, %{workspace: mount_ws})) do
      serve(conn, full, EzURI.name(uri))
    else
      _ -> forbidden(conn)
    end
  end

  def download(conn, _params), do: forbidden(conn)

  @doc """
  Back-compat shim — `GET /files/:filename`. Resolves a filename-only link under
  the caller's authenticated mount workspace (the ONE sanctioned shim, N6).
  """
  def show(conn, %{"filename" => filename}) do
    safe = Path.basename(filename)

    cond do
      safe == "" or safe == "." or safe == ".." or safe != filename ->
        conn
        |> put_status(:bad_request)
        |> text("invalid filename")

      true ->
        case mount_workspace(conn) do
          {:ok, mount_ws} ->
            uri = Uploads.resource_uri(mount_ws, safe)

            case wrap_resolve(Uploads.resolve(uri, %{workspace: mount_ws})) do
              {:ok, full} -> serve(conn, full, {:ok, safe})
              :error -> forbidden(conn)
            end

          :error ->
            forbidden(conn)
        end
    end
  end

  # --- internals -------------------------------------------------------------

  # The authenticated mount workspace — the AUTHORITATIVE subject. Derived from
  # the signed-in entity (NOT from the URI being resolved), so the ws-segment
  # authority check is non-tautological.
  defp mount_workspace(conn) do
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
