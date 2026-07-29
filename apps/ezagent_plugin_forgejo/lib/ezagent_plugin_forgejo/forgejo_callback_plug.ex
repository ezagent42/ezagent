defmodule EzagentPluginForgejo.ForgejoCallbackPlug do
  @moduledoc """
  OAuth callback endpoint for Forgejo authorization.

  Receives `GET /forgejo/callback?code=...&state=...` from the instance's
  redirect and hands both to `Ezagent.ProviderConnection.CallbackIngress`,
  which resolves the `state` back to the pending authorization and drives the
  driver's `consume_callback/1`.

  One route serves every instance: the `state` — not the host — identifies
  which pending authorization a callback belongs to, so a tenant on a second
  Forgejo server needs no second endpoint.

  ## Why the response says so little

  Both `state` and any provider-supplied error text are attacker-influenced
  values arriving in a browser-bound request. Echoing either into the response
  body is how reflected content gets in, so the body is a fixed string and the
  reason stays in the return value the ingress already recorded.
  """

  import Plug.Conn

  @doc false
  def init(opts), do: opts

  @doc false
  def call(%{params: %{"code" => code, "state" => state}} = conn, _opts)
      when is_binary(code) and is_binary(state) do
    case consume_callback(state, code) do
      {:ok, _receipt} ->
        text(conn, 200, "Forgejo authorization complete. You may close this page.")

      {:error, _reason} ->
        text(conn, 400, "Authorization failed.")
    end
  end

  def call(conn, _opts), do: text(conn, 400, "Missing code or state parameter.")

  defp text(conn, status, body) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, body)
  end

  # The production call names `CallbackIngress` directly -- a variable module
  # here would be a dynamic receiver, which the plugin-locality enumerator
  # flags (the GitHub plug's equivalent line predates that gate and sits in its
  # frozen baseline; a NEW one should not be added to it, per the
  # `arch-gate-enforcement` note: prefer making the problem disappear over
  # widening or freezing).
  #
  # Tests substitute a FUNCTION, not a module, so the override is a value this
  # module calls rather than a receiver it dispatches on.
  defp consume_callback(state, code) do
    case Application.get_env(:ezagent_plugin_forgejo, :callback_consume_fun) do
      fun when is_function(fun, 3) ->
        fun.("forgejo-oauth", state, %{code: code})

      _none ->
        Ezagent.ProviderConnection.CallbackIngress.consume("forgejo-oauth", state, %{code: code})
    end
  end
end
