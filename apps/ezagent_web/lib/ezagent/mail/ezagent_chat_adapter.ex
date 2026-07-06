defmodule Ezagent.Mail.EzagentChatAdapter do
  @moduledoc """
  Swoosh adapter that delivers via the `email.ezagent.chat` mail service's
  REST API (Cloudflare Email Sending — REST only, no SMTP relay).

  Delivery is a single `POST #{"{base_url}"}/api/send` with
  `Authorization: Bearer #{"{api_key}"}` and a JSON body:

      %{address: <sender mailbox>, to: <recipient(s)>, subject:, text:, html:}

  - `address` is the sender mailbox the key owns (taken from the email's
    `from` address). The service 403s if the key does not own it.
  - `to` is a string (or list) of recipient addresses.
  - `html` is omitted when the email has no HTML body.

  Config (per-delivery override from `EzagentWeb.Mailer`):
  `[base_url: "https://email.ezagent.chat", api_key: "emk_..."]`.

  The raw HTTP call uses Erlang's stdlib `:httpc` (the house pattern — see
  `Ezagent.Email.Inbox.CFWorker`, `Ezagent.PluginCurlAgent.ApiClient`), so no
  new HTTP-client dependency is pulled in. It is injectable for tests via the
  `:ezagent_web, :http_request_fun` app env. TLS is explicit
  (`verify_peer` + system cacerts). Transport + non-2xx errors map to
  `{:error, _}`; delivery never raises.
  """
  use Swoosh.Adapter, required_config: [:base_url, :api_key]

  alias Swoosh.Email

  @impl true
  def deliver(%Email{} = email, config) do
    {url, headers, content_type, body} = build_request(email, config)

    _ = :application.ensure_all_started(:inets)
    _ = :application.ensure_all_started(:ssl)

    http_opts = [
      {:timeout, 15_000},
      {:connect_timeout, 10_000},
      {:ssl, [verify: :verify_peer, cacerts: :public_key.cacerts_get()]}
    ]

    request = {url, headers, content_type, body}

    case request_fun().(:post, request, http_opts, body_format: :binary) do
      {:ok, {{_http, status, _reason}, _resp_headers, resp_body}}
      when status >= 200 and status < 300 ->
        {:ok, %{id: response_id(resp_body)}}

      {:ok, {{_http, status, _reason}, _resp_headers, resp_body}} ->
        {:error, {:http, status, to_string(resp_body)}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  @doc """
  Pure request builder (unit-tested offline). Returns the `:httpc` POST tuple
  parts `{url, headers, content_type, body}` with charlist url/header-values and
  a JSON-encoded body. Raises if `from` has no address (delivery cannot pick a
  sender mailbox).
  """
  @spec build_request(Email.t(), keyword()) ::
          {charlist(), [{charlist(), charlist()}], charlist(), binary()}
  def build_request(%Email{} = email, config) do
    base_url = Keyword.fetch!(config, :base_url)
    api_key = Keyword.fetch!(config, :api_key)

    url = String.to_charlist(String.trim_trailing(base_url, "/") <> "/api/send")

    headers = [
      {~c"authorization", String.to_charlist("Bearer " <> api_key)}
    ]

    payload =
      %{
        address: sender_address(email),
        to: recipients(email),
        subject: email.subject || "",
        text: email.text_body || ""
      }
      |> put_html(email.html_body)

    {url, headers, ~c"application/json", Jason.encode!(payload)}
  end

  # `from` is `{name, address}` (or a bare address string). We send the address
  # as the owning mailbox.
  defp sender_address(%Email{from: {_name, address}}) when is_binary(address), do: address
  defp sender_address(%Email{from: address}) when is_binary(address), do: address

  defp sender_address(%Email{from: from}) do
    raise ArgumentError, "EzagentChatAdapter: email has no sender address (from=#{inspect(from)})"
  end

  # `to` is a list of `{name, address}`; the REST API accepts a string or array.
  # Send a single string when there is exactly one recipient, else an array.
  defp recipients(%Email{to: to}) do
    case Enum.map(to, &recipient_address/1) do
      [one] -> one
      many -> many
    end
  end

  defp recipient_address({_name, address}) when is_binary(address), do: address
  defp recipient_address(address) when is_binary(address), do: address

  defp put_html(payload, html) when is_binary(html) and html != "",
    do: Map.put(payload, :html, html)

  defp put_html(payload, _), do: payload

  defp response_id(resp_body) do
    case Jason.decode(to_string(resp_body)) do
      {:ok, %{"id" => id}} -> id
      _ -> nil
    end
  end

  defp request_fun,
    do: Application.get_env(:ezagent_web, :http_request_fun, &:httpc.request/4)
end
