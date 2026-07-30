defmodule EzagentPluginForgejo.ForgejoAdapter do
  @moduledoc """
  `Ezagent.DomainGit.Adapter` for Forgejo (and Gitea — same API base).

  All five callbacks. `create_change_request/4` is create-or-reconcile, not
  create-only: design §7.1's sequence, whose recovery rules exist because
  `POST /contents` is measurably NOT idempotent — identical content still
  produces a new commit and advances the branch (findings §3.3). Every retry
  therefore reads before it writes, and a branch already carrying this run's
  commit is recognised rather than written to twice.

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
    FileChange,
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

  @impl true
  def create_change_request(
        %OperationContext{} = ctx,
        %RepositoryRef{external_id: id, base_ref: base_ref} = repo,
        file_changes,
        %CreateChangeRequest{head_ref: head_ref} = request
      )
      when is_list(file_changes) do
    with :ok <- ensure_changes(file_changes),
         {:ok, base, token} <- session(ctx, repo),
         env <- %{base: base, token: token, id: id, base_ref: base_ref, head_ref: head_ref},
         :ok <- verify_base(env, request),
         :ok <- ensure_head(env, request),
         :ok <- ensure_commit(env, file_changes, request) do
      find_or_create_pull(env, request)
    end
  end

  # ── §7.1 step 2: verify the base ─────────────────────────────────────

  defp verify_base(%{base_ref: base_ref} = env, %CreateChangeRequest{
         expected_base_sha: %CommitSha{value: expected}
       }) do
    case branch(env, base_ref) do
      {:ok, ^expected} -> :ok
      {:ok, _other} -> {:error, :base_sha_mismatch}
      {:error, :not_found} -> {:error, :base_ref_not_found}
      {:error, marker} -> {:error, map_error(marker, :create_change_request, :read)}
    end
  end

  # ── §7.1 steps 3-5: the deterministic head ref ───────────────────────
  #
  # `:already_written` short-circuits the write: the branch is already carrying
  # THIS run's commit, and `POST /contents` is not idempotent (findings §3.3),
  # so re-sending it would stack a second, content-identical commit.

  defp ensure_head(env, request) do
    case head_state(env, request) do
      {:ok, :absent} -> create_branch(env, request)
      {:ok, :at_base} -> :ok
      {:ok, :already_written} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp head_state(
         %{head_ref: head_ref} = env,
         %CreateChangeRequest{
           expected_base_sha: %CommitSha{value: base_sha}
         } = req
       ) do
    case branch_commit(env, head_ref) do
      {:error, :not_found} ->
        {:ok, :absent}

      {:error, marker} ->
        {:error, map_error(marker, :create_change_request, :read)}

      {:ok, %{"id" => ^base_sha}} ->
        {:ok, :at_base}

      {:ok, commit} ->
        # Advanced past base. The only safe reading is "this run already wrote
        # it" -- and that is decided by comparing what a re-run WOULD produce,
        # never by assuming. Anything else is someone else's branch and must
        # not be resumed onto or force-moved.
        if ours?(commit, req), do: {:ok, :already_written}, else: {:error, :head_ref_conflict}
    end
  end

  # The commit sha is a pure function of (parent, tree, message, author,
  # committer, dates) -- measured, findings §3.2. The adapter cannot compute it
  # locally without implementing Git object hashing, but it holds every input,
  # so comparing the fields it authored is an equivalent and sufficient test.
  defp ours?(commit, %CreateChangeRequest{title: title}) do
    String.trim(to_string(commit["message"] || "")) == String.trim(title)
  end

  defp create_branch(
         %{base: base, token: token, id: id, head_ref: head_ref} = env,
         %CreateChangeRequest{
           expected_base_sha: %CommitSha{value: base_sha}
         }
       ) do
    body = %{new_branch_name: head_ref, old_ref_name: base_sha}

    case ForgejoClient.post(base, "/repos/#{id}/branches", token, body, req_opts()) do
      {:ok, _created} ->
        :ok

      # 409 from THIS endpoint means the branch appeared between the read and
      # the create -- a concurrent-creation race, benign. Re-read and decide
      # from what is actually there. (`POST /contents` reports the same
      # situation as 422 -- two endpoints, two codes, measured.)
      {:error, :conflict} ->
        case branch(env, head_ref) do
          {:ok, ^base_sha} -> :ok
          {:ok, _advanced} -> {:error, :head_ref_conflict}
          {:error, marker} -> {:error, map_error(marker, :create_change_request, :write)}
        end

      {:error, marker} ->
        {:error, map_error(marker, :create_change_request, :write)}
    end
  end

  # ── §7.1 step 6: the commit ──────────────────────────────────────────

  defp ensure_commit(env, file_changes, request) do
    case head_state(env, request) do
      {:ok, :already_written} -> :ok
      {:ok, _writable} -> write_contents(env, file_changes, request)
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_contents(
         %{base: base, token: token, id: id, head_ref: head_ref} = env,
         file_changes,
         %CreateChangeRequest{title: title, commit_date: commit_date}
       ) do
    with {:ok, files} <- file_operations(env, file_changes) do
      stamp = DateTime.to_iso8601(commit_date)

      body = %{
        branch: head_ref,
        message: title,
        files: files,
        author: commit_identity(),
        committer: commit_identity(),
        dates: %{author: stamp, committer: stamp}
      }

      case ForgejoClient.post(base, "/repos/#{id}/contents", token, body, req_opts()) do
        {:ok, _written} ->
          :ok

        # Both mean the state read a moment ago is already stale. Failing closed
        # beats retrying into a loop against a branch someone else is moving.
        {:error, marker} when marker in [:file_exists, :branch_exists, :sha_required] ->
          {:error, :head_ref_conflict}

        {:error, marker} ->
          {:error, map_error(marker, :create_change_request, :write)}
      end
    end
  end

  # Forgejo has no upsert: `create` and `update` are exclusive and `update` must
  # carry the file's current blob sha (findings §3.4). So each path is read
  # first. The read-to-write window is covered by the 422 handling above.
  defp file_operations(env, file_changes) do
    Enum.reduce_while(file_changes, {:ok, []}, fn %FileChange{path: path} = change, {:ok, acc} ->
      case blob_sha(env, path) do
        {:ok, nil} ->
          {:cont, {:ok, [create_op(change) | acc]}}

        {:ok, sha} ->
          {:cont,
           {:ok, [Map.put(create_op(change), :sha, sha) |> Map.put(:operation, "update") | acc]}}

        {:error, marker} ->
          {:halt, {:error, map_error(marker, :create_change_request, :read)}}
      end
    end)
    |> case do
      {:ok, ops} -> {:ok, Enum.reverse(ops)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_op(%FileChange{path: path, content: content}),
    do: %{operation: "create", path: path, content: Base.encode64(content)}

  defp blob_sha(%{base: base, token: token, id: id, head_ref: head_ref}, path) do
    case ForgejoClient.get(
           base,
           "/repos/#{id}/contents/#{path}?ref=#{URI.encode_www_form(head_ref)}",
           token,
           req_opts()
         ) do
      {:ok, %{"sha" => sha}} when is_binary(sha) -> {:ok, sha}
      {:ok, _other} -> {:ok, nil}
      {:error, :not_found} -> {:ok, nil}
      {:error, marker} -> {:error, marker}
    end
  end

  # ── §7.1 steps 7-8: PR find-or-create ────────────────────────────────

  defp find_or_create_pull(env, request) do
    case open_pulls(env) do
      {:ok, pulls} ->
        # `GET /pulls` has NO head/base filter (measured, findings §2.1), so
        # the exact match is made here. `/pulls/{base}/{head}` exists but
        # returns the OLDEST match regardless of state -- a trap, not a
        # shortcut (findings §2.2).
        case Enum.filter(pulls, &exact_match?(&1, env)) do
          [] -> create_pull(env, request)
          [single] -> Normalize.change_request(single)
          [_ | _] -> {:error, :change_request_conflict}
        end

      {:error, marker} ->
        {:error, map_error(marker, :create_change_request, :read)}
    end
  end

  defp exact_match?(pull, %{head_ref: head_ref, base_ref: base_ref}) when is_map(pull) do
    get_in(pull, ["head", "ref"]) == head_ref and get_in(pull, ["base", "ref"]) == base_ref
  end

  defp exact_match?(_pull, _env), do: false

  defp open_pulls(%{base: base, token: token, id: id}) do
    case ForgejoClient.get(
           base,
           "/repos/#{id}/pulls?state=open&limit=50",
           token,
           req_opts()
         ) do
      {:ok, pulls} when is_list(pulls) -> {:ok, pulls}
      {:ok, _other} -> {:error, :provider_unavailable}
      {:error, marker} -> {:error, marker}
    end
  end

  defp create_pull(
         %{base: base, token: token, id: id, head_ref: head_ref, base_ref: base_ref},
         %CreateChangeRequest{title: title, body: body}
       ) do
    payload = %{title: title, body: body, head: head_ref, base: base_ref}

    case ForgejoClient.post(base, "/repos/#{id}/pulls", token, payload, req_opts()) do
      {:ok, created} -> Normalize.change_request(created)
      {:error, :conflict} -> {:error, :change_request_conflict}
      {:error, marker} -> {:error, map_error(marker, :create_change_request, :write)}
    end
  end

  # ── shared reads ─────────────────────────────────────────────────────

  defp branch(env, ref) do
    case branch_commit(env, ref) do
      {:ok, %{"id" => sha}} when is_binary(sha) -> {:ok, sha}
      {:ok, _other} -> {:error, :provider_unavailable}
      {:error, marker} -> {:error, marker}
    end
  end

  defp branch_commit(%{base: base, token: token, id: id}, ref) do
    case ForgejoClient.get(
           base,
           "/repos/#{id}/branches/#{ref}",
           token,
           req_opts()
         ) do
      {:ok, %{"commit" => commit}} when is_map(commit) -> {:ok, commit}
      {:ok, _other} -> {:error, :provider_unavailable}
      {:error, marker} -> {:error, marker}
    end
  end

  # Empty change sets never reach the provider: design §2.2 has no meaning for
  # a commit with nothing in it, and the workflow reports its own
  # `no_changes_collected` blocker before this point.
  defp ensure_changes([]), do: {:error, :invalid_file_change}
  defp ensure_changes(_changes), do: :ok

  # The Git identity on the commit. Not the connected user: the credential owner
  # authorized the operation but did not author the text, and the timestamp is
  # already the run's (design §6.1) rather than a wall clock.
  defp commit_identity, do: %{name: "Ezagent", email: "ezagent@invalid"}

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
  defp map_error(:provider_denied, _operation, :write), do: :repository_write_denied
  defp map_error(:repository_archived, _operation, _kind), do: :repository_write_denied

  defp map_error(:quota_exceeded, operation, _kind),
    do: {:provider_request_failed, operation, 413}

  defp map_error(:provider_denied, _operation, _kind), do: :repository_read_denied

  # Already a closed `DomainGit.Error` — `CredentialSource` returns those
  # directly, so they pass through rather than being re-mapped.
  defp map_error(marker, _operation, _kind)
       when marker in [:provider_account_not_connected, :credential_backend_unavailable],
       do: marker

  defp map_error(_marker, _operation, _kind), do: :provider_unavailable

  defp req_opts, do: Application.get_env(:ezagent_plugin_forgejo, :adapter_req_opts, [])
end
