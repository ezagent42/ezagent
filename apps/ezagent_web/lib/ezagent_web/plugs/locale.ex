defmodule EzagentWeb.Plugs.Locale do
  @moduledoc """
  Sets the `EzagentWeb.Gettext` locale per request, in priority order:

  1. `?locale=<code>` query param (if present and supported) → also
     persisted into the session so subsequent page loads stay translated.
     This is the minimal switcher mechanism — no UI element needed.
  2. `:locale` session key (user preference set via the query-param flow
     above, or a future profile-page setting).
  3. `Accept-Language` request header (browser preference). Coarse parse:
     looks for `zh` substring → `zh_CN`, otherwise falls back to default.
  4. Default `"en"`.

  Mount in the `:browser` pipeline AFTER `:fetch_session` so the session
  is readable + writable.

  Also calls `Gettext.put_locale/2` for BOTH `EzagentWeb.Gettext` and
  `EzagentDomainUi.Gettext` (the Tier-2 shared-component backend) so any
  Gettext call during this request (controller, layout, dead-render
  LiveView mount, domain_ui shell component) sees the resolved locale.
  `Gettext.put_locale/2` is per-backend process-dictionary state, so
  both backends must be set explicitly.

  Assigns:

  - `:current_locale` — the resolved locale string (`"en"` or `"zh_CN"`).
    LV `on_mount` hook reads `session["locale"]` to inherit the same
    locale into the LV websocket process (separate BEAM process from
    the request).
  """

  import Plug.Conn

  @supported ~w(en zh_CN)
  @default "en"

  @doc "Locales recognized by `EzagentWeb.Gettext`."
  def supported_locales, do: @supported

  @doc "Fallback when no preference is detected."
  def default_locale, do: @default

  def init(opts), do: opts

  def call(conn, _opts) do
    {locale, conn} = resolve(conn)
    Gettext.put_locale(EzagentWeb.Gettext, locale)
    # Tier-2 shared-component backend — set explicitly; `put_locale/2`
    # is per-backend process-dictionary state.
    Gettext.put_locale(EzagentDomainUi.Gettext, locale)

    conn
    |> put_session(:locale, locale)
    |> assign(:current_locale, locale)
  end

  defp resolve(conn) do
    cond do
      qp = supported_query_param(conn) ->
        {qp, conn}

      sess = get_session(conn, :locale) ->
        if sess in @supported, do: {sess, conn}, else: {from_header(conn), conn}

      true ->
        {from_header(conn), conn}
    end
  end

  defp supported_query_param(conn) do
    conn = Plug.Conn.fetch_query_params(conn)

    case Map.get(conn.query_params, "locale") do
      locale when locale in @supported -> locale
      _ -> nil
    end
  end

  defp from_header(conn) do
    case get_req_header(conn, "accept-language") do
      [header | _] when is_binary(header) ->
        if String.contains?(String.downcase(header), "zh"), do: "zh_CN", else: @default

      _ ->
        @default
    end
  end
end
