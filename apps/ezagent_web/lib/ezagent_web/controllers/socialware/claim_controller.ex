defmodule EzagentWeb.Socialware.ClaimController do
  @moduledoc """
  Generic landing for a URI-share link (A1) — `GET /socialware/claim?token=`.

  The HTTP entry a bearer share link points at. A logged-in user (`RequireEntity`
  guarantees `current_entity_uri`) opens the link carrying only the signed
  `token` (`Ezagent.Cap.ShareToken`, minted by whoever shared, naming any target
  URI + the behavior/actions it grants). This controller is **plugin-agnostic** —
  it neither knows nor names kanban (or any plugin): it delegates to
  `Ezagent.Socialware.Share.claim/2`, which verifies the token and mints a
  grantee-bound cap toward the target for the clicker (cap-as-truth `甲`:
  bearer → mint). The shared thing then shows up in the clicker's own space via
  cap-derived visibility — no server-side session/host resolution here.

    * valid token → cap minted, 302 to the world root (the clicker's space);
    * bad / expired / tampered token, or a target with no owner to grant from →
      403 (fail-closed).

  A future plugin that wants a deep-link landing can carry a return path; A1
  keeps the landing generic (the world root) since the target may be any URI.
  """
  use EzagentWeb, :controller

  alias Ezagent.Socialware.Share

  def claim(conn, %{"token" => token}) when is_binary(token) do
    clicker = conn.assigns.current_entity_uri

    case Share.claim(token, clicker) do
      {:ok, _result} ->
        conn
        |> put_flash(:info, "分享已加入你的工作区。")
        |> redirect(to: ~p"/")

      {:error, reason} ->
        reject(conn, reason)
    end
  end

  def claim(conn, _params), do: reject(conn, :missing_token)

  defp reject(conn, reason) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(403, "share link rejected: #{inspect(reason)}")
  end
end
