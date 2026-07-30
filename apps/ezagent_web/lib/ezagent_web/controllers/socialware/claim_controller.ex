defmodule EzagentWeb.Socialware.ClaimController do
  @moduledoc """
  Generic landing for a URI-share link (A1) — `GET /socialware/claim?token=`.

  The HTTP entry a bearer share link points at. A logged-in user (`RequireEntity`
  guarantees `current_entity_uri`) opens the link carrying only the signed
  `token` (`Ezagent.Cap.ShareToken`, minted by whoever shared, naming any target
  URI + the behavior/actions it grants). This controller is **plugin-agnostic** —
  it neither knows nor names kanban (or any plugin): it delegates to
  `Ezagent.Socialware.Share.claim/2`, which verifies the token, confirms the
  target's sharing setting is CURRENTLY enabled by its CURRENT owner, and
  RECORDS a `ShareClaim` for the clicker (Feishu model A) — it mints **no**
  durable capability. Access is re-derived LIVE at the domain read gate
  (`Share.shared_to?/2`, checked on every read) from the claim plus the live
  sharing setting, so the owner disabling sharing cuts every claimer off on
  their very next read, instantly, for everyone.

    * valid token + sharing enabled → claim recorded, 302 to the world root
      (the clicker's space);
    * bad / expired / tampered token, sharing disabled, or a stale setting
      whose owner has since transferred → 403 (fail-closed).

  A future plugin that wants a deep-link landing can carry a return path; A1
  keeps the landing generic (the world root) since the target may be any URI.
  """
  use EzagentWeb, :controller

  alias Ezagent.Socialware.Share

  @doc """
  Claim a bearer share link: verify the `token` and record a `ShareClaim` for
  the logged-in clicker against its target (`Share.claim/2` — mints no cap;
  access is re-derived live via `Share.shared_to?/2` on every subsequent read),
  then 302 to the world root. A bad/expired/tampered token, a missing token,
  disabled sharing, or a stale setting (owner transferred since it was
  enabled) → 403 (fail-closed).
  """
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
