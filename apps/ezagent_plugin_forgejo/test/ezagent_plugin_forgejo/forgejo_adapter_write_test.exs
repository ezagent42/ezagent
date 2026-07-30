defmodule EzagentPluginForgejo.ForgejoAdapterWriteTest do
  @moduledoc """
  Slice F3 — `create_change_request/4`, create-or-reconcile.

  The sequence and every recovery rule here come from design §7, which rests on
  measured Forgejo behaviour (findings §3):

    * `POST /contents` is NOT idempotent — identical content still creates a new
      commit and advances the branch — so a retry must read before it writes;
    * a commit sha IS reproducible from the same inputs, which is what lets a
      resume recognise its own previous attempt;
    * `POST /branches` accepts a commit sha as `old_ref_name`, so the branch can
      be pinned to the verified base;
    * duplicate-branch conflicts arrive as 409 from `POST /branches` but 422
      from `POST /contents` — two endpoints, two codes.
  """
  use ExUnit.Case, async: false

  alias Ezagent.DomainGit.{CreateChangeRequest, FileChange, OperationContext, RepositoryRef}
  alias Ezagent.ProviderConnection.Connection
  alias EzagentCore.Repo
  alias EzagentPluginForgejo.{ForgejoAdapter, ForgejoCredentialBackend}

  @stub :forgejo_adapter_write_test
  @ws "workspace://acme"
  @owner "entity://acme/user/dev"
  @host "code.hyprial.test"
  @repo_id "gagameow/ezagent-forgejo-test"
  @base_sha String.duplicate("1", 40)
  @head_sha String.duplicate("2", 40)
  @head_ref "task/p4e/run-abc123"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    {:ok, %{credential_ref: ref}} =
      ForgejoCredentialBackend.store(%{
        workspace_uri: "workspace://acme",
        credential_material: {:write_only_handoff, Jason.encode!(%{"access_token" => "at-live"})}
      })

    Repo.insert!(%Connection{
      connection_id: Ecto.UUID.generate(),
      workspace_uri: @ws,
      owner_uri: @owner,
      provider_id: "forgejo",
      governed_host: @host,
      execution_identity: "connected_user",
      external_account_id: "7",
      acquisition_method: "oauth_user",
      status: "active",
      credential_backend_ref: ref,
      credential_version: 1,
      authorization_backend_ref: "auth-w",
      backend_pair_id: "pair-forgejo-v1",
      authorization_backend_id: "local-authorization-v1",
      credential_backend_id: "forgejo-credential-v1"
    })

    :ok
  end

  # Routes by {method, path} so a test declares only the responses it cares
  # about, and records every request so "how many writes happened" is answerable.
  defp stub(routes) do
    test_pid = self()

    Req.Test.stub(@stub, fn conn ->
      key = {conn.method, conn.request_path}
      send(test_pid, {:request, key})

      case Map.get(routes, key) do
        nil -> Plug.Conn.resp(conn, 599, ~s({"message":"unstubbed #{inspect(key)}"}))
        fun when is_function(fun, 1) -> fun.(conn)
      end
    end)

    previous = Application.get_env(:ezagent_plugin_forgejo, :adapter_req_opts)
    Application.put_env(:ezagent_plugin_forgejo, :adapter_req_opts, plug: {Req.Test, @stub})

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:ezagent_plugin_forgejo, :adapter_req_opts)
        value -> Application.put_env(:ezagent_plugin_forgejo, :adapter_req_opts, value)
      end
    end)

    :ok
  end

  defp json(body), do: fn conn -> Req.Test.json(conn, body) end

  defp status(code, body \\ ~s({"message":"x"})),
    do: fn conn -> Plug.Conn.resp(conn, code, body) end

  defp jsonc(code, body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(code, Jason.encode!(body))
    end
  end

  defp ctx do
    hash = String.duplicate("a", 64)

    {:ok, context} =
      OperationContext.new(%{
        task_access_uri: Ezagent.URI.new!("entity://acme/worker/gta_#{hash}"),
        caller_uri: Ezagent.URI.new!("entity://acme/agent/codex"),
        grantee_uri: Ezagent.URI.new!("entity://acme/agent/codex"),
        credential_owner_uri: Ezagent.URI.new!(@owner),
        idempotency_key: "write-1"
      })

    context
  end

  defp repo! do
    {:ok, ref} =
      RepositoryRef.new(%{
        repository_uri: Ezagent.URI.new!("resource://acme/git-repository/main"),
        provider_adapter: :forgejo,
        provider_host: @host,
        external_id: @repo_id,
        owner_path: "gagameow",
        base_ref: "main",
        visibility: :private
      })

    ref
  end

  defp changes do
    {:ok, change} = FileChange.new(%{path: "docs/a.md", operation: :upsert, content: "hello\n"})
    [change]
  end

  defp request!(overrides \\ %{}) do
    {:ok, req} =
      CreateChangeRequest.new(
        Map.merge(
          %{
            title: "Automated change",
            body: "from a run",
            head_ref: @head_ref,
            expected_base_sha: base_sha_value(),
            commit_date: ~U[2026-07-29 10:00:00Z]
          },
          overrides
        )
      )

    req
  end

  defp base_sha_value do
    {:ok, sha} = Ezagent.DomainGit.CommitSha.new(%{value: @base_sha})
    sha
  end

  # ── route fragments ──────────────────────────────────────────────────

  defp base_ok,
    do:
      {{"GET", "/api/v1/repos/#{@repo_id}/branches/main"},
       json(%{"name" => "main", "commit" => %{"id" => @base_sha}})}

  defp head_missing, do: {{"GET", "/api/v1/repos/#{@repo_id}/branches/#{@head_ref}"}, status(404)}

  defp head_at(sha, extra \\ %{}) do
    commit = Map.merge(%{"id" => sha}, extra)

    {{"GET", "/api/v1/repos/#{@repo_id}/branches/#{@head_ref}"},
     json(%{"name" => @head_ref, "commit" => commit})}
  end

  defp branch_created,
    do:
      {{"POST", "/api/v1/repos/#{@repo_id}/branches"},
       json(%{"name" => @head_ref, "commit" => %{"id" => @base_sha}})}

  defp file_absent,
    do: {{"GET", "/api/v1/repos/#{@repo_id}/contents/docs/a.md"}, status(404)}

  defp contents_written,
    do:
      {{"POST", "/api/v1/repos/#{@repo_id}/contents"}, json(%{"commit" => %{"sha" => @head_sha}})}

  defp no_open_pr, do: {{"GET", "/api/v1/repos/#{@repo_id}/pulls"}, json([])}

  defp pr_created do
    {{"POST", "/api/v1/repos/#{@repo_id}/pulls"},
     json(%{
       "number" => 7,
       "html_url" => "https://#{@host}/#{@repo_id}/pulls/7",
       "state" => "open",
       "merged" => false,
       "head" => %{"ref" => @head_ref, "sha" => @head_sha},
       "base" => %{"ref" => "main"}
     })}
  end

  defp happy_path,
    do:
      Map.new([
        base_ok(),
        head_missing(),
        branch_created(),
        file_absent(),
        contents_written(),
        no_open_pr(),
        pr_created()
      ])

  # ── first execution ──────────────────────────────────────────────────

  describe "first execution (design §7.1)" do
    test "verifies base, creates the branch pinned at base, writes, opens a PR" do
      stub(happy_path())

      assert {:ok, cr} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())

      assert cr.external_id == "7"
      assert cr.head_ref == @head_ref
      assert cr.state == :open
    end

    # `POST /branches` accepts a commit sha as old_ref_name (measured), so the
    # branch starts at the base the caller verified -- not at whatever `main`
    # happens to point at by the time the write lands.
    test "the branch is pinned to the expected base sha, not to the base ref name" do
      test_pid = self()

      routes =
        happy_path()
        |> Map.put({"POST", "/api/v1/repos/#{@repo_id}/branches"}, fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:branch_body, Jason.decode!(body)})
          Req.Test.json(conn, %{"name" => @head_ref})
        end)

      stub(routes)

      assert {:ok, _} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())

      assert_received {:branch_body, body}
      assert body["new_branch_name"] == @head_ref
      assert body["old_ref_name"] == @base_sha
    end

    # Design §6.1 / findings §3.1-3.2: the commit date must be the caller's, so
    # a retry rebuilds a byte-identical commit and reproduces its sha.
    test "the commit carries the caller's commit_date, never a wall clock" do
      test_pid = self()

      routes =
        happy_path()
        |> Map.put({"POST", "/api/v1/repos/#{@repo_id}/contents"}, fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:contents_body, Jason.decode!(body)})
          Req.Test.json(conn, %{"commit" => %{"sha" => @head_sha}})
        end)

      stub(routes)

      assert {:ok, _} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())

      assert_received {:contents_body, body}
      assert body["dates"]["author"] == "2026-07-29T10:00:00Z"
      assert body["dates"]["committer"] == "2026-07-29T10:00:00Z"
      assert body["branch"] == @head_ref
      # `new_branch` must NOT be sent: the branch already exists by now, and
      # sending it yields 422 (measured).
      refute Map.has_key?(body, "new_branch")
    end

    test "a base sha that does not match the branch head fails closed" do
      routes =
        Map.put(
          happy_path(),
          elem(base_ok(), 0),
          json(%{"name" => "main", "commit" => %{"id" => String.duplicate("9", 40)}})
        )

      stub(routes)

      assert {:error, :base_sha_mismatch} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())
    end

    test "a missing base ref is base_ref_not_found" do
      stub(Map.put(happy_path(), elem(base_ok(), 0), status(404)))

      assert {:error, :base_ref_not_found} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())
    end

    test "an empty change set is refused before anything is written" do
      stub(happy_path())

      assert {:error, :invalid_file_change} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), [], request!())

      refute_received {:request, {"POST", _}}
    end
  end

  # ── upsert mapping (design §7.3) ─────────────────────────────────────

  describe "upsert mapping" do
    # Forgejo has no upsert. `create` and `update` are exclusive, and `update`
    # must carry the file's current blob sha -- so each path is read first.
    test "an absent file is created" do
      test_pid = self()

      routes =
        happy_path()
        |> Map.put({"POST", "/api/v1/repos/#{@repo_id}/contents"}, fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:op, Jason.decode!(body)["files"]})
          Req.Test.json(conn, %{"commit" => %{"sha" => @head_sha}})
        end)

      stub(routes)

      assert {:ok, _} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())

      assert_received {:op, [file]}
      assert file["operation"] == "create"
      refute Map.has_key?(file, "sha")
    end

    test "an existing file is updated with its current blob sha" do
      test_pid = self()

      routes =
        happy_path()
        |> Map.put(elem(file_absent(), 0), json(%{"sha" => "blob-sha-1", "path" => "docs/a.md"}))
        |> Map.put({"POST", "/api/v1/repos/#{@repo_id}/contents"}, fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:op, Jason.decode!(body)["files"]})
          Req.Test.json(conn, %{"commit" => %{"sha" => @head_sha}})
        end)

      stub(routes)

      assert {:ok, _} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())

      assert_received {:op, [file]}
      assert file["operation"] == "update"
      assert file["sha"] == "blob-sha-1"
    end

    # The read-then-write window: if the file changed in between, Forgejo says
    # so and the adapter must fail closed rather than retry forever.
    test "a file that changed between read and write fails closed" do
      routes =
        happy_path()
        |> Map.put(
          {"POST", "/api/v1/repos/#{@repo_id}/contents"},
          jsonc(422, %{"message" => "repository file already exists [path: docs/a.md]"})
        )

      stub(routes)

      assert {:error, :head_ref_conflict} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())
    end
  end

  # ── crash windows (design §7.5) ──────────────────────────────────────

  describe "resume: branch exists but is still at base" do
    # Window: branch created, contents never written. The branch sitting at base
    # is safe to write into.
    test "writes into the existing branch rather than failing" do
      routes =
        happy_path()
        |> Map.put(elem(head_missing(), 0), elem(head_at(@base_sha), 1))
        |> Map.delete({"POST", "/api/v1/repos/#{@repo_id}/branches"})

      stub(routes)

      assert {:ok, %{external_id: "7"}} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())

      # No branch creation attempt: it already exists.
      refute_received {:request, {"POST", "/api/v1/repos/#{@repo_id}/branches"}}
    end
  end

  describe "resume: branch already advanced" do
    # THE dangerous window (findings §3.3): `POST /contents` is not idempotent,
    # so re-sending the write would stack a second, content-identical commit.
    # The branch already carrying this run's commit must be recognised and the
    # write skipped.
    test "recognises its own commit and does NOT write again" do
      routes =
        happy_path()
        |> Map.put(
          elem(head_missing(), 0),
          elem(
            head_at(@head_sha, %{
              "message" => "Automated change",
              "author" => %{"name" => "Ezagent", "email" => "ezagent@invalid"}
            }),
            1
          )
        )
        |> Map.delete({"POST", "/api/v1/repos/#{@repo_id}/branches"})
        |> Map.delete({"POST", "/api/v1/repos/#{@repo_id}/contents"})

      stub(routes)

      assert {:ok, %{external_id: "7", head_sha: head_sha}} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())

      assert head_sha == @head_sha
      refute_received {:request, {"POST", "/api/v1/repos/#{@repo_id}/contents"}}
    end

    # A branch advanced past base by something that is NOT this run must not be
    # resumed onto and must never be force-moved.
    test "a foreign commit on the branch is head_ref_conflict" do
      routes =
        happy_path()
        |> Map.put(
          elem(head_missing(), 0),
          elem(head_at(@head_sha, %{"message" => "someone else's work"}), 1)
        )

      stub(routes)

      assert {:error, :head_ref_conflict} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())

      refute_received {:request, {"POST", "/api/v1/repos/#{@repo_id}/contents"}}
    end
  end

  describe "resume: PR already open" do
    # Window: branch and commit landed, PR created, receipt lost. The exact
    # head+base match must be reused rather than opening a second PR.
    test "reuses the existing PR instead of creating a second one" do
      routes =
        happy_path()
        |> Map.put(
          elem(no_open_pr(), 0),
          json([
            %{
              "number" => 7,
              "html_url" => "https://#{@host}/#{@repo_id}/pulls/7",
              "state" => "open",
              "merged" => false,
              "head" => %{"ref" => @head_ref, "sha" => @head_sha},
              "base" => %{"ref" => "main"}
            }
          ])
        )
        |> Map.delete({"POST", "/api/v1/repos/#{@repo_id}/pulls"})

      stub(routes)

      assert {:ok, %{external_id: "7"}} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())

      refute_received {:request, {"POST", "/api/v1/repos/#{@repo_id}/pulls"}}
    end

    # A PR for a DIFFERENT head must not be mistaken for ours. `GET /pulls` has
    # no head/base filter (measured), so the match is made client-side and a
    # near-miss must not count.
    test "a PR on another head is not mistaken for this run's" do
      routes =
        happy_path()
        |> Map.put(
          elem(no_open_pr(), 0),
          json([
            %{
              "number" => 99,
              "html_url" => "https://#{@host}/#{@repo_id}/pulls/99",
              "state" => "open",
              "merged" => false,
              "head" => %{"ref" => "task/p4e/run-other", "sha" => @head_sha},
              "base" => %{"ref" => "main"}
            }
          ])
        )

      stub(routes)

      assert {:ok, %{external_id: "7"}} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())
    end

    # §7.4: more than one exact match is ambiguous and must stop, not pick.
    test "two PRs on the same head+base fail closed" do
      duplicate = fn number ->
        %{
          "number" => number,
          "html_url" => "https://#{@host}/#{@repo_id}/pulls/#{number}",
          "state" => "open",
          "merged" => false,
          "head" => %{"ref" => @head_ref, "sha" => @head_sha},
          "base" => %{"ref" => "main"}
        }
      end

      routes = Map.put(happy_path(), elem(no_open_pr(), 0), json([duplicate.(7), duplicate.(8)]))
      stub(routes)

      assert {:error, :change_request_conflict} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())
    end
  end

  describe "conflict codes are not interchangeable" do
    # Measured: duplicate branch is 409 from POST /branches but 422 from
    # POST /contents. A 409 on branch creation is a concurrent-creation race —
    # benign, re-read and continue.
    test "a 409 on branch creation is a race, not a failure" do
      # Models the race honestly with a STATEFUL route: the first read finds no
      # branch, the create loses to a concurrent creation (409), and the re-read
      # then finds the branch sitting at base. A fixed 404 on that route would
      # have been a fixture contradicting its own premise.
      {:ok, reads} = Agent.start_link(fn -> 0 end)

      routes =
        happy_path()
        |> Map.put(
          {"POST", "/api/v1/repos/#{@repo_id}/branches"},
          status(409, ~s({"message":"The branch already exists."}))
        )
        |> Map.put({"GET", "/api/v1/repos/#{@repo_id}/branches/#{@head_ref}"}, fn conn ->
          case Agent.get_and_update(reads, &{&1, &1 + 1}) do
            0 -> Plug.Conn.resp(conn, 404, ~s({"message":"branch does not exist"}))
            _ -> Req.Test.json(conn, %{"name" => @head_ref, "commit" => %{"id" => @base_sha}})
          end
        end)

      stub(routes)

      assert {:ok, %{external_id: "7"}} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())
    end
  end

  describe "transport failure during the write" do
    # The remote state is unknown: the commit may or may not exist. Reporting
    # status 0 tells the caller to re-read rather than assume either way.
    test "is reported as status 0, never as a refusal" do
      routes =
        happy_path()
        |> Map.put(
          {"POST", "/api/v1/repos/#{@repo_id}/contents"},
          fn conn -> Req.Test.transport_error(conn, :timeout) end
        )

      stub(routes)

      assert {:error, {:provider_request_failed, :create_change_request, 0}} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())
    end
  end
end
