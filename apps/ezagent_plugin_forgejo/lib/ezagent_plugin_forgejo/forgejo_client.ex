defmodule EzagentPluginForgejo.ForgejoClient do
  @moduledoc """
  Thin Req wrapper for the Forgejo (and Gitea) REST API.

  The base URL is a **parameter**, not a module attribute: Forgejo is
  self-hosted, so it is derived per call from the binding's provider host via
  `EzagentPluginForgejo.Instance.api_base/1` (design §5.2).

  Every call injects:

    * `Authorization: token <PAT>` — **not** `Bearer`. Forgejo's swagger is
      explicit ("API tokens must be prepended with `token` followed by a
      space"); the GitHub spelling yields 401 against a real instance.
    * `Accept: application/json`
    * `User-Agent: ezagent-forgejo-plugin`

  ## Returns

  Success (HTTP 2xx) → `{:ok, decoded_body}`.
  Failure → `{:error, marker}` where `marker` is a **neutral, closed** atom.

  The markers are deliberately protocol-level, not domain-level: this client
  does not know whether a 404 means "no such repository" or "no such branch",
  so it never guesses. Each adapter call site maps the marker to the
  `Ezagent.DomainGit.Error` code its own operation semantics imply — the same
  split `EzagentPluginGithub.GitHubClient` uses.
  """

  @doc "Issues a GET against a Forgejo instance."
  @spec get(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map() | list()} | {:error, atom()}
  def get(base, path, token, opts \\ [])
      when is_binary(base) and is_binary(path) and is_binary(token) do
    (base <> path)
    |> Req.get(Keyword.merge(base_opts(token), opts))
    |> handle_response()
  end

  @doc "Issues a POST with a JSON body against a Forgejo instance."
  @spec post(String.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, map() | list()} | {:error, atom()}
  def post(base, path, token, body, opts \\ [])
      when is_binary(base) and is_binary(path) and is_binary(token) and is_map(body) do
    (base <> path)
    |> Req.post(Keyword.merge([json: body] ++ base_opts(token), opts))
    |> handle_response()
  end

  # `retry: false` is load-bearing, for the reasons #1613 established on the
  # GitHub client: Req's `:safe_transient` default silently turns one logical
  # attempt into four requests with backoff sleeps, which (a) deepens a rate
  # limit, (b) makes the workflow's bounded retry budget wrong by 4x, and
  # (c) sleeps inside an adapter callback holding a credential. `opts` merges
  # LAST, so a call site with a genuine need passes its own `retry:`.
  defp base_opts(token) do
    [
      retry: false,
      headers: [
        {"authorization", "token #{token}"},
        {"accept", "application/json"},
        {"user-agent", "ezagent-forgejo-plugin"}
      ]
    ]
  end

  # ── error mapping ────────────────────────────────────────────────────

  defp handle_response({:ok, %{status: status, body: body}}) when status in 200..299,
    do: {:ok, body}

  defp handle_response({:ok, %{status: 401}}), do: {:error, :authentication_rejected}
  defp handle_response({:ok, %{status: 403}}), do: {:error, :provider_denied}
  defp handle_response({:ok, %{status: 404}}), do: {:error, :not_found}
  defp handle_response({:ok, %{status: 409}}), do: {:error, :conflict}
  defp handle_response({:ok, %{status: 413}}), do: {:error, :quota_exceeded}
  defp handle_response({:ok, %{status: 423}}), do: {:error, :repository_archived}
  defp handle_response({:ok, %{status: 429}}), do: {:error, :provider_rate_limited}
  defp handle_response({:ok, %{status: 422, body: body}}), do: {:error, classify_422(body)}
  defp handle_response({:ok, _response}), do: {:error, :provider_unavailable}

  # A transport failure and a 5xx are NOT the same event, and the write path's
  # recovery turns on telling them apart (design §8.3): a 5xx means the request
  # reached the instance and was refused, so the remote state is known; a
  # transport failure means the response never came back, so the request may or
  # may not have taken effect and the caller MUST re-read before deciding.
  # Collapsing both into one code is the known, still-unfixed defect on the
  # GitHub client -- not a precedent to copy.
  defp handle_response({:error, _exception}), do: {:error, :provider_unreachable}

  # Forgejo overloads 422 across three situations the write path must tell
  # apart. Matching on the message text is unpleasant but it is the only
  # signal the API gives -- status and headers are identical for all three.
  # The strings are verbatim from live probes (findings §3.3); an
  # unrecognised body stays neutral rather than being forced into one of the
  # three, so a future Forgejo wording change degrades to "unclassified"
  # instead of silently misclassifying.
  defp classify_422(%{"message" => message}) when is_binary(message) do
    cond do
      String.contains?(message, "branch already exists") -> :branch_exists
      String.contains?(message, "repository file already exists") -> :file_exists
      String.contains?(message, "a SHA or commit ID must be provided") -> :sha_required
      true -> :unprocessable_entity
    end
  end

  defp classify_422(_body), do: :unprocessable_entity
end
