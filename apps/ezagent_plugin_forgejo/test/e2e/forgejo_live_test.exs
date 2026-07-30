defmodule EzagentPluginForgejo.E2E.ForgejoLiveTest do
  @moduledoc """
  Slice F5 — the adapter against a REAL Forgejo instance.

  Default-excluded (`:live_forgejo`, see `test/test_helper.exs`), following the
  `:live_github` / `:live_miro` precedent: it needs credentials, network, and it
  mutates a real repository.

  ## Running it

      FORGEJO_LIVE_TOKEN=<pat> FORGEJO_LIVE_REPO=<owner>/<repo> \\
      FORGEJO_LIVE_HOST=code.hyprial.com \\
      mix test apps/ezagent_plugin_forgejo/test/e2e --include live_forgejo

  `FORGEJO_LIVE_PROXY` is optional but usually required on this machine.

  ## The proxy, and a correction

  An earlier note in the design claimed this instance was directly reachable
  and needed no proxy, on the strength of a bare `curl` returning 200. That was
  wrong: the shell exports `https_proxy=http://127.0.0.1:7890`, which curl
  honours silently. With `curl --noproxy '*'` the same request times out after
  25s; through the proxy it returns 200 in 1.5s.

  Req/Finch do **not** read `https_proxy` (handoff §5.3), so the proxy must be
  passed explicitly as `connect_options: [proxy: ...]` — exactly the same
  arrangement the GitHub lane already documents. Without it the symptom is
  `%Req.TransportError{reason: :timeout}`, which this adapter reports as
  `{:provider_request_failed, op, 0}`.

  ## What is real and what is not

  Real: the instance, the branch, the commit, the pull request, and the
  credential path (a connection row whose credential the adapter leases per
  callback).

  Not real: the OAuth browser round-trip. A PAT is seeded into the credential
  backend directly, which is sound for this purpose precisely because the
  measured authentication behaviour makes them interchangeable at the transport
  layer — `Authorization: token <value>` is accepted for both a PAT and an
  OAuth2 access token (findings §7.1). What this therefore does NOT cover is
  the acquisition flow itself; that is exercised in
  `forgejo_driver_test.exs` and by the manual authorization already recorded in
  findings §7.

  ## Observation, not interception

  The Req step below copies `{method, path}` to the test process **before** the
  request leaves. It does not stub, rewrite or count on behalf of the provider.
  Counting a stand-in's requests measures the stand-in (handoff §6.2), so every
  assertion about what exists afterwards is made by re-reading the instance.

  ## Residue

  A successful run leaves one branch and one open pull request on the target
  repository, named after the run. `on_exit` attempts to close the PR and
  delete the branch, and tolerates failure — cleanup is a courtesy, not an
  assertion, and a failed cleanup must not turn a passing verification red.
  """
  use ExUnit.Case, async: false

  @moduletag :live_forgejo
  # Real network round-trips against a remote instance.
  @moduletag timeout: 300_000

  alias Ezagent.DomainGit.{
    ChangeRequestId,
    CommitSha,
    CreateChangeRequest,
    FileChange,
    OperationContext,
    RepositoryRef
  }

  alias Ezagent.ProviderConnection.Connection
  alias EzagentCore.Repo
  alias EzagentPluginForgejo.{ForgejoAdapter, ForgejoClient, ForgejoCredentialBackend, Instance}

  @ws "workspace://acme"
  @owner "entity://acme/user/dev"

  setup_all do
    with {:ok, token} <- env("FORGEJO_LIVE_TOKEN"),
         {:ok, repo_id} <- env("FORGEJO_LIVE_REPO"),
         {:ok, host} <- env("FORGEJO_LIVE_HOST") do
      {:ok,
       token: token, repo_id: repo_id, host: host, proxy: System.get_env("FORGEJO_LIVE_PROXY")}
    else
      {:error, missing} ->
        raise """
        #{missing} is not set.

        This suite talks to a real Forgejo instance. Export FORGEJO_LIVE_TOKEN,
        FORGEJO_LIVE_REPO (owner/repo) and FORGEJO_LIVE_HOST, then re-run with
        `--include live_forgejo`.
        """
    end
  end

  setup %{token: token, repo_id: repo_id, host: host, proxy: proxy} do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    test_pid = self()

    # Pass-through observer, same shape as `github_live_case.ex`: a `plugins:`
    # entry appending ONE request step that copies {method, path} and returns
    # the request untouched. It does not answer, rewrite or count on the
    # provider's behalf.
    observer = fn req ->
      Req.Request.append_request_steps(req,
        ezagent_forgejo_live_probe: fn r ->
          send(test_pid, {:observed, r.method, r.url.path})
          r
        end
      )
    end

    previous = Application.get_env(:ezagent_plugin_forgejo, :adapter_req_opts)

    Application.put_env(
      :ezagent_plugin_forgejo,
      :adapter_req_opts,
      [retry: false, plugins: [observer]] ++ proxy_opts(proxy)
    )

    {:ok, %{credential_ref: ref}} =
      ForgejoCredentialBackend.store(%{
        credential_material: {:write_only_handoff, Jason.encode!(%{"access_token" => token})}
      })

    Repo.insert!(%Connection{
      connection_id: Ecto.UUID.generate(),
      workspace_uri: @ws,
      owner_uri: @owner,
      provider_id: "forgejo",
      governed_host: host,
      execution_identity: "connected_user",
      external_account_id: "live",
      acquisition_method: "oauth_user",
      status: "active",
      credential_backend_ref: ref,
      credential_version: 1,
      authorization_backend_ref: "auth-live",
      backend_pair_id: "pair-forgejo-v1",
      authorization_backend_id: "local-authorization-v1",
      credential_backend_id: "forgejo-credential-v1"
    })

    # One ref per run so a re-run never collides with the previous residue,
    # while staying stable WITHIN a run — the double-execution assertion needs
    # the same ref twice.
    run_id = System.system_time(:second) |> Integer.to_string()
    head_ref = "task/live/run-#{run_id}"

    on_exit(fn ->
      cleanup(host, repo_id, token, head_ref)

      case previous do
        nil -> Application.delete_env(:ezagent_plugin_forgejo, :adapter_req_opts)
        value -> Application.put_env(:ezagent_plugin_forgejo, :adapter_req_opts, value)
      end
    end)

    {:ok, head_ref: head_ref, run_id: run_id}
  end

  test "the full read+write loop against the real instance, run twice", %{
    token: token,
    repo_id: repo_id,
    host: host,
    head_ref: head_ref,
    run_id: run_id
  } do
    {:ok, base} = Instance.api_base(host)
    repo = repo!(repo_id, host)

    # The base sha is read from the instance, not assumed.
    assert {:ok, %{"commit" => %{"id" => base_sha}}} =
             ForgejoClient.get(base, "/repos/#{repo_id}/branches/main", token, req_opts())

    assert {:ok, ^repo} = ForgejoAdapter.resolve_repository(ctx(), repo)

    request = request!(head_ref, base_sha, run_id)
    changes = changes(run_id)

    assert {:ok, first} = ForgejoAdapter.create_change_request(ctx(), repo, changes, request)
    assert first.head_ref == head_ref
    assert first.base_ref == "main"
    assert first.state == :open

    # Confirmed by re-reading the instance, not by trusting the create response.
    assert {:ok, %{"commit" => %{"id" => head_after_first}}} =
             ForgejoClient.get(
               base,
               "/repos/#{repo_id}/branches/#{head_ref}",
               token,
               req_opts()
             )

    assert head_after_first == first.head_sha
    refute head_after_first == base_sha

    # ── the assertion this slice exists for ──────────────────────────
    # `POST /contents` is not idempotent on a real instance (findings §3.3), so
    # a second pass that re-sent the write would leave the branch one commit
    # further along and a second PR open.
    assert {:ok, second} = ForgejoAdapter.create_change_request(ctx(), repo, changes, request)

    assert second.external_id == first.external_id
    assert second.head_sha == first.head_sha

    assert {:ok, %{"commit" => %{"id" => head_after_second}}} =
             ForgejoClient.get(
               base,
               "/repos/#{repo_id}/branches/#{head_ref}",
               token,
               req_opts()
             )

    assert head_after_second == head_after_first,
           "the second pass advanced the branch — the write was not skipped"

    # Exactly one open PR for this head, read back from the instance.
    assert {:ok, pulls} =
             ForgejoClient.get(
               base,
               "/repos/#{repo_id}/pulls?state=open&limit=50",
               token,
               req_opts()
             )

    mine = Enum.filter(pulls, &(get_in(&1, ["head", "ref"]) == head_ref))
    assert length(mine) == 1

    # ── the read path, against the same real PR ──────────────────────
    {:ok, id} = ChangeRequestId.new(%{external_id: first.external_id})
    {:ok, head} = CommitSha.new(%{value: first.head_sha})

    assert {:ok, read_back} = ForgejoAdapter.read_change_request(ctx(), repo, id)
    assert read_back.external_id == first.external_id
    assert read_back.state == :open

    # A fresh PR has no checks and no reviews. Empty is a valid fact and must
    # not be reported as a pass or an approval (Plan E §6.3).
    assert {:ok, checks} = ForgejoAdapter.list_checks(ctx(), repo, head)
    assert is_list(checks)

    assert {:ok, reviews} = ForgejoAdapter.list_reviews(ctx(), repo, id)
    assert is_list(reviews)

    # The observer proves which endpoints were actually reached. The measured
    # trap is `/statuses` (re-run history); the adapter must have used the
    # combined `/status` instead.
    observed = drain_observed()

    assert Enum.any?(observed, &String.ends_with?(&1, "/status")),
           "the combined status endpoint was never called"

    refute Enum.any?(observed, &String.ends_with?(&1, "/statuses")),
           "the adapter read the status HISTORY endpoint"

    # No returned value carries the credential.
    for value <- [first, second, read_back, checks, reviews] do
      refute inspect(value) =~ token
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────

  defp drain_observed(acc \\ []) do
    receive do
      {:observed, _method, path} -> drain_observed([path | acc])
    after
      0 -> acc
    end
  end

  # Req/Finch ignore `https_proxy` (handoff §5.3), so it is passed explicitly.
  defp proxy_opts(nil), do: []

  defp proxy_opts(proxy) do
    uri = URI.parse(proxy)
    [connect_options: [proxy: {:http, uri.host, uri.port, []}]]
  end

  defp env(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _absent -> {:error, name}
    end
  end

  defp req_opts, do: Application.get_env(:ezagent_plugin_forgejo, :adapter_req_opts, [])

  defp ctx do
    hash = String.duplicate("a", 64)

    {:ok, context} =
      OperationContext.new(%{
        task_access_uri: Ezagent.URI.new!("entity://acme/worker/gta_#{hash}"),
        caller_uri: Ezagent.URI.new!("entity://acme/agent/codex"),
        grantee_uri: Ezagent.URI.new!("entity://acme/agent/codex"),
        credential_owner_uri: Ezagent.URI.new!(@owner),
        idempotency_key: "live-1"
      })

    context
  end

  defp repo!(repo_id, host) do
    [owner | _] = String.split(repo_id, "/")

    {:ok, ref} =
      RepositoryRef.new(%{
        repository_uri: Ezagent.URI.new!("resource://acme/git-repository/live"),
        provider_adapter: :forgejo,
        provider_host: host,
        external_id: repo_id,
        owner_path: owner,
        base_ref: "main",
        visibility: :private
      })

    ref
  end

  defp changes(run_id) do
    {:ok, change} =
      FileChange.new(%{
        path: "ezagent-live/#{run_id}.md",
        operation: :upsert,
        content: "Written by the Forgejo provider live E2E, run #{run_id}.\n"
      })

    [change]
  end

  defp request!(head_ref, base_sha, run_id) do
    {:ok, sha} = CommitSha.new(%{value: base_sha})

    {:ok, req} =
      CreateChangeRequest.new(%{
        title: "ezagent live E2E run #{run_id}",
        body: "Opened by the Forgejo provider's live end-to-end test.",
        head_ref: head_ref,
        expected_base_sha: sha,
        # Fixed, not a wall clock: this is what makes the retried commit
        # byte-identical and its sha reproducible (design §6.1).
        commit_date: ~U[2026-07-29 10:00:00Z]
      })

    req
  end

  # Courtesy only, and deliberately NOT routed through `ForgejoClient`: closing
  # a PR needs PATCH and removing a branch needs DELETE, neither of which the
  # adapter performs. Adding them to the production client so a test could tidy
  # up would widen the provider surface for a reason production never has.
  #
  # Every step is best-effort. A failed cleanup must not turn a passing
  # verification red, so nothing here is asserted.
  defp cleanup(host, repo_id, token, head_ref) do
    with {:ok, base} <- Instance.api_base(host) do
      headers = [{"authorization", "token #{token}"}, {"accept", "application/json"}]

      opts = [headers: headers, retry: false] ++ proxy_opts(System.get_env("FORGEJO_LIVE_PROXY"))

      case Req.get(base <> "/repos/#{repo_id}/pulls?state=open&limit=50", opts) do
        {:ok, %{status: 200, body: pulls}} when is_list(pulls) ->
          for pull <- pulls, get_in(pull, ["head", "ref"]) == head_ref do
            Req.patch(
              base <> "/repos/#{repo_id}/pulls/#{pull["number"]}",
              Keyword.put(opts, :json, %{state: "closed"})
            )
          end

        _other ->
          :ok
      end

      Req.delete(base <> "/repos/#{repo_id}/branches/#{head_ref}", opts)
    end

    :ok
  rescue
    _error -> :ok
  end
end
