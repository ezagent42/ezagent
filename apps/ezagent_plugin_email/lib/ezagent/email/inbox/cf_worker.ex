defmodule Ezagent.Email.Inbox.CFWorker do
  @moduledoc """
  `Ezagent.Email.Inbox` backend that pulls from the Cloudflare Email Worker's
  HTTP API (`GET /inbox[?to=]`, `GET /inbox/<key>`, `DELETE /inbox/<key>`),
  authenticating with `Authorization: Bearer <pull_token>`. URL building + JSON
  decoding are pure; the raw `:httpc` call is injectable for tests via the
  `:http_request_fun` app env. TLS is explicit (`verify_peer` + cacerts) — a
  deliberate improvement over the house :httpc callers which set no ssl opts.
  """
  @behaviour Ezagent.Email.Inbox

  @impl true
  def list(config, opts) do
    {method, url, headers} = build(config, {:list, Keyword.get(opts, :to)})

    case do_request(method, url, headers) do
      {:ok, 200, body} -> {:ok, decode_list(body)}
      {:ok, status, _} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def fetch(config, key) do
    {method, url, headers} = build(config, {:fetch, key})

    case do_request(method, url, headers) do
      {:ok, 200, body} -> {:ok, decode_one(body)}
      {:ok, 404, _} -> {:error, :not_found}
      {:ok, status, _} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete(config, key) do
    {method, url, headers} = build(config, {:delete, key})

    case do_request(method, url, headers) do
      {:ok, status, _} when status in [200, 204] -> :ok
      {:ok, 404, _} -> {:error, :not_found}
      {:ok, status, _} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- pure helpers (unit-tested) ---

  @doc false
  def build(%{"pull_url" => base, "pull_token" => token}, op) do
    headers = [{~c"authorization", String.to_charlist("Bearer " <> token)}]

    case op do
      {:list, nil} -> {:get, url(base, "/inbox"), headers}
      {:list, to} -> {:get, url(base, "/inbox?to=" <> URI.encode_www_form(to)), headers}
      {:fetch, key} -> {:get, url(base, "/inbox/" <> URI.encode(key)), headers}
      {:delete, key} -> {:delete, url(base, "/inbox/" <> URI.encode(key)), headers}
    end
  end

  defp url(base, path), do: String.to_charlist(String.trim_trailing(base, "/") <> path)

  @doc false
  def decode_list(body) do
    case Jason.decode(body) do
      {:ok, %{"emails" => emails}} when is_list(emails) -> emails
      _ -> []
    end
  end

  @doc false
  def decode_one(body) do
    case Jason.decode(body) do
      {:ok, %{} = rec} -> rec
      _ -> %{}
    end
  end

  # --- impure transport (injectable) ---

  defp do_request(method, url, headers) do
    http_opts = [
      {:timeout, 15_000},
      {:connect_timeout, 10_000},
      {:ssl, [verify: :verify_peer, cacerts: :public_key.cacerts_get()]}
    ]

    request = {url, headers}

    case request_fun().(method, request, http_opts, []) do
      {:ok, {{_, status, _}, _headers, body}} -> {:ok, status, to_string(body)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request_fun, do: Application.get_env(:ezagent_plugin_email, :http_request_fun, &:httpc.request/4)
end
