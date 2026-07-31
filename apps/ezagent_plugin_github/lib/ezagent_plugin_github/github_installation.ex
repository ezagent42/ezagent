defmodule EzagentPluginGithub.GitHubInstallation do
  @moduledoc """
  Mints GitHub App **operation-scoped installation access tokens** — the
  credential used for repository operations (contents, PRs, checks).

  In the GitHub App model, repo access does NOT come from the connecting user's
  token; it comes from the App's installation on the repo's account. Every call to
  `token_for_operation/3`:

    1. Signs an App JWT (`EzagentPluginGithub.GitHubAppJwt`).
    2. `GET /repos/{owner}/{repo}/installation` (JWT auth) to resolve the
       installation `id` for that repo — deterministic: a repo belongs to exactly
       one installation.
    3. `POST /app/installations/{id}/access_tokens` (JWT auth) to mint a token
       scoped to exactly that repository and the caller's closed permission
       profile (`EzagentPluginGithub.InstallationPermissions`).
    4. Strictly validates the response's `token`, `repository_selection`,
       `repositories`, `permissions`, and `expires_at` against the request before
       returning the token — a missing/empty/non-binary token, any scope
       mismatch or widening, or a missing/malformed/already-past `expires_at`
       fails closed with `{:error, :installation_scope_mismatch}` before any
       repository HTTP call.

  There is no cache: every call mints fresh. A token returned by this module is
  meant to live only on the caller's current call stack for one adapter callback
  (or one observation tick) — it must not be stored in ETS, process state,
  persistent_term, or any durable structure, and must not cross callback
  boundaries.
  """

  alias EzagentPluginGithub.{GitHubAppJwt, GitHubClient, InstallationPermissions}
  alias Ezagent.DomainGit.RepositoryRef

  @type permission_profile :: InstallationPermissions.profile()

  @doc """
  Mints a fresh installation access token scoped to exactly `repo.external_id`
  and the closed `profile` permission map.

  `opts` are passed through to the underlying `GitHubClient` HTTP calls (e.g.
  `plug: {Req.Test, name}` for stubbing); they default to the
  `:installation_req_opts` application env, with any passed-in `opts` taking
  precedence.

  Returns `{:ok, token}` or `{:error, reason}` where `reason` is a stable
  `GitHubClient` error atom (`:authentication_rejected`, `:repository_not_found`,
  `:provider_denied`, `:provider_unavailable`, …), `:installation_scope_mismatch`
  when a readable response does not exactly match the requested repository and
  permissions, or `:provider_response_unrecognized` when a 2xx response could not
  be read at all — either the installation lookup without an `id`, or a mint body
  whose scope fields are absent or wrongly typed. Only the transport-level
  answers are worth retrying; the other two are terminal and say different
  things to an operator ("scoped wrong" vs "shape changed"). Raises (fail-loud) only if the App private key is missing or
  malformed — an operations misconfiguration, deliberately distinct from a
  GitHub-side rejection.
  """
  @spec token_for_operation(RepositoryRef.t(), permission_profile(), Keyword.t()) ::
          {:ok, String.t()} | {:error, atom()}
  def token_for_operation(%RepositoryRef{external_id: repo_full_name}, profile, opts \\ [])
      when is_binary(repo_full_name) and is_atom(profile) do
    # Fail-loud on a missing/malformed key happens inside generate/0.
    jwt = GitHubAppJwt.generate()
    req_opts = merged_opts(opts)
    permissions = InstallationPermissions.for!(profile)

    with {:ok, %{"id" => installation_id}} <-
           GitHubClient.get("/repos/#{repo_full_name}/installation", jwt, req_opts),
         {:ok, response} <-
           GitHubClient.post(
             "/app/installations/#{installation_id}/access_tokens",
             jwt,
             %{repositories: [repo_short_name(repo_full_name)], permissions: permissions},
             req_opts
           ) do
      validate_scope(response, repo_full_name, permissions)
    else
      {:error, reason} -> {:error, reason}
      {:ok, _unexpected_shape} -> {:error, :provider_response_unrecognized}
    end
  end

  # ── Request shaping ──────────────────────────────────────────────────────

  defp repo_short_name(repo_full_name) do
    repo_full_name |> String.split("/") |> List.last()
  end

  # ── Strict response validation ──────────────────────────────────────────
  # Must reject before the caller makes its first repository HTTP call:
  # wider-than-requested permissions, an "all"-repositories grant, any repository
  # other than exactly the one requested, a missing/empty/non-binary token, or a
  # missing/malformed/already-past expires_at. Returns `{:ok, token}` only when
  # every field checks out.

  # SHAPE first, SCOPE second — they are different answers to different
  # questions, and one clause answering both collapsed them.
  #
  # A mint body carrying none of these fields used to be reported as
  # `:installation_scope_mismatch`, which tells an operator the credential came
  # back scoped wrong. Nothing was scoped: the response shape had changed. Both
  # codes are terminal, so no run behaves differently — the CAUSE an operator
  # reads does, and that is the whole point of the distinction.
  defp validate_scope(
         %{
           "token" => token,
           "repository_selection" => repository_selection,
           "repositories" => repositories,
           "permissions" => permissions,
           "expires_at" => expires_at
         },
         repo_full_name,
         requested_permissions
       )
       when is_binary(token) and is_binary(repository_selection) and is_list(repositories) and
              is_map(permissions) and is_binary(expires_at) do
    scoped_as_requested(
      {token, repository_selection, repositories, expires_at},
      permissions,
      repo_full_name,
      requested_permissions
    )
  end

  # The five scope fields are not all present and of the right primitive type,
  # so there is no scope here to agree or disagree with.
  defp validate_scope(_response, _repo_full_name, _requested_permissions),
    do: {:error, :provider_response_unrecognized}

  # Readable — now is it what we asked for? A wrong value here IS a scope
  # mismatch: an "all"-repositories grant, a repository other than the one
  # requested, permissions that do not match, an empty token, or an expiry that
  # will not parse or has already passed.
  defp scoped_as_requested(
         {token, "selected", [%{"full_name" => full_name}], expires_at},
         permissions,
         repo_full_name,
         requested_permissions
       )
       when token != "" and full_name == repo_full_name and
              permissions == requested_permissions do
    case DateTime.from_iso8601(expires_at) do
      {:ok, dt, _offset} ->
        if DateTime.compare(dt, DateTime.utc_now()) == :gt do
          {:ok, token}
        else
          {:error, :installation_scope_mismatch}
        end

      {:error, _reason} ->
        {:error, :installation_scope_mismatch}
    end
  end

  defp scoped_as_requested(_readable, _permissions, _repo_full_name, _requested_permissions),
    do: {:error, :installation_scope_mismatch}

  # ── Config ───────────────────────────────────────────────────────────────

  defp merged_opts(opts) do
    Application.get_env(:ezagent_plugin_github, :installation_req_opts, [])
    |> Keyword.merge(opts)
  end
end
