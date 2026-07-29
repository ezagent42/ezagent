defmodule EzagentPluginForgejo.ForgejoAdapter do
  @moduledoc """
  `Ezagent.DomainGit.Adapter` for Forgejo (and Gitea — same API base).

  Slice F2 delivers the four read callbacks. `create_change_request/4` is F3 and
  currently refuses rather than pretending; see its clause.

  ## Every callback leases the credential again

  Design §4.2. Nothing is cached across callbacks: a credential revoked between
  two operations must stop working at the second one, and a cache would keep it
  alive. The plaintext token exists only between
  `EzagentPluginForgejo.CredentialSource.access_token/3` and the HTTP call.

  Unlike the GitHub adapter there is nothing to mint — the credential was
  issued once at authorization time — so each callback resolves the stored
  connection for `ctx.credential_owner_uri` on this repository's instance.

  ## Error mapping is per call site

  `EzagentPluginForgejo.ForgejoClient` returns protocol-level markers and
  refuses to guess what a 404 or 403 means; the same status means different
  things depending on the operation. A 5xx keeps its status through
  `{:provider_request_failed, op, status}`, and a transport failure reports
  status `0` — an explicit "no HTTP response arrived", which matters because
  the remote state is then unknown (design §8.3).
  """

  @behaviour Ezagent.DomainGit.Adapter

  alias Ezagent.DomainGit.{
    ChangeRequestId,
    CommitSha,
    CreateChangeRequest,
    OperationContext,
    RepositoryRef
  }

  alias EzagentPluginForgejo.{CredentialSource, ForgejoClient, Instance, Normalize}

  @impl true
  def resolve_repository(%OperationContext{} = ctx, %RepositoryRef{external_id: id} = repo) do
    with {:ok, base, token} <- session(ctx, repo),
         {:ok, %{"full_name" => _full_name}} <-
           ForgejoClient.get(base, "/repos/#{id}", token, req_opts()) do
      {:ok, repo}
    else
      {:ok, _unexpected} -> {:error, :provider_unavailable}
      {:error, marker} -> {:error, map_error(marker, :resolve_repository, :read)}
    end
  end

  @impl true
  def read_change_request(
        %OperationContext{} = ctx,
        %RepositoryRef{external_id: id} = repo,
        %ChangeRequestId{external_id: external_id}
      ) do
    with {:ok, base, token} <- session(ctx, repo),
         {:ok, body} <-
           ForgejoClient.get(
             base,
             "/repos/#{id}/pulls/#{external_id}",
             token,
             req_opts()
           ) do
      Normalize.change_request(body)
    else
      {:error, marker} -> {:error, map_error(marker, :read_change_request, :read)}
    end
  end

  @impl true
  def list_checks(
        %OperationContext{} = ctx,
        %RepositoryRef{external_id: id} = repo,
        %CommitSha{value: sha}
      ) do
    # The COMBINED endpoint (`/status`), never `/statuses`. Measured: the
    # latter returns the full re-run history — 56 entries across 17 contexts on
    # a single head, one context repeated 7 times — which would become several
    # `Check` records sharing a name and contradicting each other.
    with {:ok, base, token} <- session(ctx, repo),
         {:ok, body} <-
           ForgejoClient.get(
             base,
             "/repos/#{id}/commits/#{sha}/status",
             token,
             req_opts()
           ) do
      Normalize.checks(body)
    else
      {:error, marker} -> {:error, map_error(marker, :list_checks, :checks)}
    end
  end

  @impl true
  def list_reviews(
        %OperationContext{} = ctx,
        %RepositoryRef{external_id: id} = repo,
        %ChangeRequestId{external_id: external_id}
      ) do
    with {:ok, base, token} <- session(ctx, repo),
         {:ok, body} <-
           ForgejoClient.get(
             base,
             "/repos/#{id}/pulls/#{external_id}/reviews",
             token,
             req_opts()
           ) do
      Normalize.reviews(body)
    else
      {:error, marker} -> {:error, map_error(marker, :list_reviews, :read)}
    end
  end

  # Slice F3. Refusing is not a stub that pretends: a caller gets a closed
  # error rather than a success that wrote nothing. The write path needs the
  # read-before-write reconciliation from design §7.1, which is its own slice.
  @impl true
  def create_change_request(
        %OperationContext{},
        %RepositoryRef{},
        file_changes,
        %CreateChangeRequest{}
      )
      when is_list(file_changes) do
    {:error, :repository_write_denied}
  end

  # ── internals ────────────────────────────────────────────────────────

  # One lease per callback, and the base URL derived from THIS repository's
  # instance — two bindings in one VM routinely point at different servers.
  defp session(%OperationContext{credential_owner_uri: owner_uri}, %RepositoryRef{
         provider_host: host
       }) do
    with {:ok, base} <- Instance.api_base(host),
         {:ok, workspace} <- workspace_of(owner_uri),
         {:ok, token} <- CredentialSource.access_token(workspace, URI.to_string(owner_uri), host) do
      {:ok, base, token}
    end
  end

  defp workspace_of(owner_uri) do
    case Ezagent.URI.workspace_name(owner_uri) do
      {:ok, workspace} -> {:ok, "workspace://" <> workspace}
      :error -> {:error, :provider_account_not_connected}
    end
  end

  # `ForgejoClient`'s markers are protocol-level on purpose. The same status
  # means different things per operation, so each call site supplies the
  # reading: a 403 on a repository read is a read denial, the same 403 on the
  # checks endpoint means checks are unavailable.
  defp map_error({:provider_status, status}, operation, _kind),
    do: {:provider_request_failed, operation, status}

  # Status 0 is the explicit "no HTTP response arrived" marker. It is NOT a
  # refusal: the request may or may not have reached the instance, so a caller
  # must re-read before deciding anything (design §8.3).
  defp map_error(:provider_unreachable, operation, _kind),
    do: {:provider_request_failed, operation, 0}

  defp map_error(:authentication_rejected, _operation, _kind), do: :authentication_rejected
  defp map_error(:provider_rate_limited, _operation, _kind), do: :provider_rate_limited
  defp map_error(:not_found, _operation, _kind), do: :repository_not_found
  defp map_error(:provider_denied, _operation, :checks), do: :checks_unavailable
  defp map_error(:provider_denied, _operation, _kind), do: :repository_read_denied

  # Already a closed `DomainGit.Error` — `CredentialSource` returns those
  # directly, so they pass through rather than being re-mapped.
  defp map_error(marker, _operation, _kind)
       when marker in [:provider_account_not_connected, :credential_backend_unavailable],
       do: marker

  defp map_error(_marker, _operation, _kind), do: :provider_unavailable

  defp req_opts, do: Application.get_env(:ezagent_plugin_forgejo, :adapter_req_opts, [])
end
