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

      # `?ref=` is recorded SEPARATELY so a test can assert which ref a read was
      # bound to. Routing on `request_path` alone meant the content-provenance
      # tests passed even if the code read `main`, or dropped `ref` entirely —
      # the fixture answered the same sha regardless, so those tests proved
      # nothing about the ref.
      ref =
        conn
        |> Plug.Conn.fetch_query_params()
        |> Map.fetch!(:query_params)
        |> Map.get("ref")

      send(test_pid, {:request, key})
      send(test_pid, {:read_ref, elem(key, 1), ref})

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

  # A list route must behave like a paginated endpoint or the adapter's
  # read-to-exhaustion loop never terminates: a fixture that returns the same
  # list for every `page` is not a simplification, it is a contradiction of the
  # API it stands in for. Page 1 gets the body, every later page gets `[]`.
  defp json(body) when is_list(body) do
    fn conn ->
      page =
        conn
        |> Plug.Conn.fetch_query_params()
        |> Map.fetch!(:query_params)
        |> Map.get("page", "1")

      Req.Test.json(conn, if(page == "1", do: body, else: []))
    end
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

  # git blob sha = sha1("blob <byte_size>\0" <> content). Forgejo's `/contents`
  # returns exactly this (measured), which is what makes a local content check
  # possible without fetching the file body.
  defp blob_sha_of(content) do
    :crypto.hash(:sha, "blob #{byte_size(content)}\0" <> content) |> Base.encode16(case: :lower)
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

  # The file already carrying exactly what `changes()` would write. Needed by
  # every "recognises its own commit" fixture: provenance now includes content,
  # so a branch that advanced with our commit must ALSO show our blob.
  defp file_is_ours,
    do:
      {{"GET", "/api/v1/repos/#{@repo_id}/contents/docs/a.md"},
       json(%{"sha" => blob_sha_of("hello\n")})}

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
        |> Map.put(elem(file_is_ours(), 0), elem(file_is_ours(), 1))
        |> Map.put(
          elem(head_missing(), 0),
          elem(
            # Every field `write_contents/3` pins. An earlier version of this
            # fixture carried only message+author, which is why it kept passing
            # while `ours?/2` compared the message alone.
            head_at(@head_sha, %{
              "message" => "Automated change",
              "timestamp" => "2026-07-29T18:00:00+08:00",
              "author" => %{"name" => "Ezagent", "email" => "ezagent@invalid"},
              "committer" => %{"name" => "Ezagent", "email" => "ezagent@invalid"}
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

    # The message alone is NOT a provenance criterion: a PR title is public and
    # anyone can write a commit carrying it. Resuming onto such a branch would
    # skip the write and open a PR pointing at SOMEONE ELSE'S content.
    #
    # The adapter pins `dates` and `author`/`committer` on every commit it
    # writes, so a commit it authored carries all of them. Any one of them
    # differing means the branch is not this run's.
    test "a foreign commit that happens to share our title is still a conflict" do
      foreign = %{
        "message" => "Automated change",
        "timestamp" => "2020-01-01T00:00:00Z",
        "author" => %{"name" => "Someone Else", "email" => "other@invalid"},
        "committer" => %{"name" => "Someone Else", "email" => "other@invalid"}
      }

      routes =
        happy_path()
        |> Map.put(elem(head_missing(), 0), elem(head_at(@head_sha, foreign), 1))

      stub(routes)

      assert {:error, :head_ref_conflict} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())

      refute_received {:request, {"POST", "/api/v1/repos/#{@repo_id}/contents"}}
    end

    test "a foreign commit sharing our title AND identity but not our date is a conflict" do
      foreign = %{
        "message" => "Automated change",
        "timestamp" => "2020-01-01T00:00:00Z",
        "author" => %{"name" => "Ezagent", "email" => "ezagent@invalid"},
        "committer" => %{"name" => "Ezagent", "email" => "ezagent@invalid"}
      }

      routes =
        happy_path()
        |> Map.put(elem(head_missing(), 0), elem(head_at(@head_sha, foreign), 1))

      stub(routes)

      assert {:error, :head_ref_conflict} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())
    end

    # `commit_date` is `git_workflow_runs.inserted_at`, and that table is
    # `timestamps(type: :utc_datetime_usec)` — so it carries MICROSECONDS. Git
    # stores commit times as epoch SECONDS, and Forgejo echoes them without a
    # fractional part (measured). Comparing the two as instants therefore never
    # matched, and the adapter stopped recognising ITS OWN commit: every
    # lost-response resume reported `:head_ref_conflict` instead of converging.
    #
    # The earlier fixture hid this by using a whole-second `commit_date`.
    test "its own commit is recognised when commit_date carries microseconds" do
      ours = %{
        "message" => "Automated change",
        "timestamp" => "2026-07-29T18:00:00+08:00",
        "author" => %{"name" => "Ezagent", "email" => "ezagent@invalid"},
        "committer" => %{"name" => "Ezagent", "email" => "ezagent@invalid"}
      }

      routes =
        happy_path()
        |> Map.put(elem(file_is_ours(), 0), elem(file_is_ours(), 1))
        |> Map.put(elem(head_missing(), 0), elem(head_at(@head_sha, ours), 1))

      stub(routes)

      request = request!(%{commit_date: ~U[2026-07-29 10:00:00.123456Z]})

      assert {:ok, _result} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request)

      refute_received {:request, {"POST", "/api/v1/repos/#{@repo_id}/contents"}}
    end

    # Metadata alone cannot prove provenance. `ours?/2` compares message,
    # identity and date — all of which a DIFFERENT set of file changes under the
    # same run would share, because they are derived from the run, not from the
    # content. Without a content check the adapter would skip the second write
    # and open a PR pointing at the FIRST attempt's content.
    #
    # Forgejo's `/contents` returns the standard git blob sha (measured), so
    # "what would we write" is computable locally at zero request cost.
    test "a commit whose metadata matches but whose content differs is a conflict" do
      ours_metadata = %{
        "message" => "Automated change",
        "timestamp" => "2026-07-29T18:00:00+08:00",
        "author" => %{"name" => "Ezagent", "email" => "ezagent@invalid"},
        "committer" => %{"name" => "Ezagent", "email" => "ezagent@invalid"}
      }

      routes =
        happy_path()
        |> Map.put(elem(head_missing(), 0), elem(head_at(@head_sha, ours_metadata), 1))
        # The file at head carries SOMEONE ELSE'S content.
        |> Map.put(
          {"GET", "/api/v1/repos/#{@repo_id}/contents/docs/a.md"},
          json(%{"sha" => blob_sha_of("not what we would write\n")})
        )

      stub(routes)

      assert {:error, :head_ref_conflict} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())

      refute_received {:request, {"POST", "/api/v1/repos/#{@repo_id}/contents"}}
    end

    # The same shape, but the content DOES match: this is our own commit and the
    # write must be skipped rather than stacking a second identical commit.
    test "a commit whose metadata AND content match is recognised" do
      ours_metadata = %{
        "message" => "Automated change",
        "timestamp" => "2026-07-29T18:00:00+08:00",
        "author" => %{"name" => "Ezagent", "email" => "ezagent@invalid"},
        "committer" => %{"name" => "Ezagent", "email" => "ezagent@invalid"}
      }

      routes =
        happy_path()
        |> Map.put(elem(head_missing(), 0), elem(head_at(@head_sha, ours_metadata), 1))
        |> Map.put(
          {"GET", "/api/v1/repos/#{@repo_id}/contents/docs/a.md"},
          json(%{"sha" => blob_sha_of("hello\n")})
        )

      stub(routes)

      assert {:ok, _cr} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())

      refute_received {:request, {"POST", "/api/v1/repos/#{@repo_id}/contents"}}
    end

    # A file we would create that is ABSENT at head means the commit did not
    # come from this call, whatever its metadata says.
    test "a commit whose metadata matches but which is missing our file is a conflict" do
      ours_metadata = %{
        "message" => "Automated change",
        "timestamp" => "2026-07-29T18:00:00+08:00",
        "author" => %{"name" => "Ezagent", "email" => "ezagent@invalid"},
        "committer" => %{"name" => "Ezagent", "email" => "ezagent@invalid"}
      }

      routes =
        happy_path()
        |> Map.put(elem(head_missing(), 0), elem(head_at(@head_sha, ours_metadata), 1))
        |> Map.put({"GET", "/api/v1/repos/#{@repo_id}/contents/docs/a.md"}, status(404))

      stub(routes)

      assert {:error, :head_ref_conflict} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())
    end

    # The metadata came from ONE commit; the content must be read from THAT
    # commit, not from the branch name. A branch can advance between the
    # metadata read and each content read, and then every file can match
    # individually while no single commit carries the whole expected set —
    # `:already_written` would open a PR whose head contains something else.
    test "content is read from the commit the metadata came from, not the branch" do
      ours = %{
        "message" => "Automated change",
        "timestamp" => "2026-07-29T18:00:00+08:00",
        "author" => %{"name" => "Ezagent", "email" => "ezagent@invalid"},
        "committer" => %{"name" => "Ezagent", "email" => "ezagent@invalid"}
      }

      routes =
        happy_path()
        |> Map.put(elem(head_missing(), 0), elem(head_at(@head_sha, ours), 1))
        |> Map.put(elem(file_is_ours(), 0), elem(file_is_ours(), 1))

      stub(routes)

      assert {:ok, _cr} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())

      # The provenance read must be pinned to the commit id.
      assert_received {:read_ref, "/api/v1/repos/#{@repo_id}/contents/docs/a.md", @head_sha}
    end

    # A read that FAILED is not evidence that the content differs. Collapsing
    # both into "not ours" turns a transient 5xx or timeout during a resume into
    # `:head_ref_conflict` — which the workflow treats as a terminal blocker,
    # so one flaky read permanently wedges a run whose write actually landed.
    # Design §8.3: a transport failure means the remote state is UNKNOWN.
    test "a transient failure reading content is not reported as a conflict" do
      ours = %{
        "message" => "Automated change",
        "timestamp" => "2026-07-29T18:00:00+08:00",
        "author" => %{"name" => "Ezagent", "email" => "ezagent@invalid"},
        "committer" => %{"name" => "Ezagent", "email" => "ezagent@invalid"}
      }

      routes =
        happy_path()
        |> Map.put(elem(head_missing(), 0), elem(head_at(@head_sha, ours), 1))
        |> Map.put(
          {"GET", "/api/v1/repos/#{@repo_id}/contents/docs/a.md"},
          status(503, ~s({"message":"upstream unavailable"}))
        )

      stub(routes)

      assert {:error, {:provider_request_failed, :create_change_request, 503}} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())
    end

    # `/contents` returns four `type`s and the `sha` does NOT mean the same thing
    # for all of them (measured on the target instance):
    #
    #   file     -> blob sha of the content
    #   symlink  -> blob sha of the TARGET PATH string (still a blob sha)
    #   submodule-> the pointed-at COMMIT sha, not a blob sha at all
    #   dir      -> a tree sha
    #
    # Comparing a blob sha against a submodule's commit sha can only ever be
    # false, so a path that is a submodule where this run wants a plain file
    # would report `:head_ref_conflict` forever — a fail-closed wedge dressed up
    # as a concurrency conflict. It must be a distinguishable error.
    test "a submodule where we would write a file is a distinguishable error" do
      ours = %{
        "message" => "Automated change",
        "timestamp" => "2026-07-29T18:00:00+08:00",
        "author" => %{"name" => "Ezagent", "email" => "ezagent@invalid"},
        "committer" => %{"name" => "Ezagent", "email" => "ezagent@invalid"}
      }

      routes =
        happy_path()
        |> Map.put(elem(head_missing(), 0), elem(head_at(@head_sha, ours), 1))
        |> Map.put(
          {"GET", "/api/v1/repos/#{@repo_id}/contents/docs/a.md"},
          json(%{"type" => "submodule", "sha" => String.duplicate("9", 40)})
        )

      stub(routes)

      assert {:error, :invalid_file_change} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())
    end

    # A symlink's sha IS a blob sha (of the target path), so no special case is
    # needed for the comparison to be correct — it simply will not match a plain
    # file's content, which is the right answer.
    test "a symlink where we would write a file is a conflict, not a crash" do
      ours = %{
        "message" => "Automated change",
        "timestamp" => "2026-07-29T18:00:00+08:00",
        "author" => %{"name" => "Ezagent", "email" => "ezagent@invalid"},
        "committer" => %{"name" => "Ezagent", "email" => "ezagent@invalid"}
      }

      routes =
        happy_path()
        |> Map.put(elem(head_missing(), 0), elem(head_at(@head_sha, ours), 1))
        |> Map.put(
          {"GET", "/api/v1/repos/#{@repo_id}/contents/docs/a.md"},
          json(%{
            "type" => "symlink",
            "target" => "README.md",
            "sha" => blob_sha_of("README.md")
          })
        )

      stub(routes)

      assert {:error, :head_ref_conflict} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())
    end

    # A plain file with no `type` at all (older instance, or a shape this probe
    # did not see) must still work: absence of the field is not evidence of a
    # non-file.
    test "a response without a type field is treated as a file" do
      ours = %{
        "message" => "Automated change",
        "timestamp" => "2026-07-29T18:00:00+08:00",
        "author" => %{"name" => "Ezagent", "email" => "ezagent@invalid"},
        "committer" => %{"name" => "Ezagent", "email" => "ezagent@invalid"}
      }

      routes =
        happy_path()
        |> Map.put(elem(head_missing(), 0), elem(head_at(@head_sha, ours), 1))
        |> Map.put(
          {"GET", "/api/v1/repos/#{@repo_id}/contents/docs/a.md"},
          json(%{"sha" => blob_sha_of("hello\n")})
        )

      stub(routes)

      assert {:ok, _cr} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())
    end

    # The resume window this check exists to serve: our own commit landed but
    # the response was lost. Every pinned field matches, so the write is
    # skipped rather than stacking a second content-identical commit.
    test "our own commit is recognised and the write is skipped" do
      ours = %{
        "message" => "Automated change",
        "timestamp" => "2026-07-29T10:00:00Z",
        "author" => %{"name" => "Ezagent", "email" => "ezagent@invalid"},
        "committer" => %{"name" => "Ezagent", "email" => "ezagent@invalid"}
      }

      routes =
        happy_path()
        |> Map.put(elem(file_is_ours(), 0), elem(file_is_ours(), 1))
        |> Map.put(elem(head_missing(), 0), elem(head_at(@head_sha, ours), 1))

      stub(routes)

      assert {:ok, _result} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())

      refute_received {:request, {"POST", "/api/v1/repos/#{@repo_id}/contents"}}
    end
  end

  describe "concurrent identical runs converge" do
    # Two identical runs race. A creates the branch and writes; B's
    # `POST /branches` comes back 409. Re-reading only to ask "is it still at
    # base?" makes B report a conflict against ITS OWN logical work — the run is
    # deterministic, so A's commit is the one B would have written. B must go
    # back through the full head reconciliation, recognise it, and converge.
    test "a 409 on branch creation reconciles instead of assuming conflict" do
      ours = %{
        "message" => "Automated change",
        "timestamp" => "2026-07-29T10:00:00Z",
        "author" => %{"name" => "Ezagent", "email" => "ezagent@invalid"},
        "committer" => %{"name" => "Ezagent", "email" => "ezagent@invalid"}
      }

      # Absent on the first read (B decides to create), advanced-and-ours after
      # the 409 (A got there first).
      counter = :counters.new(1, [])

      routes =
        happy_path()
        |> Map.put(elem(file_is_ours(), 0), elem(file_is_ours(), 1))
        |> Map.put(
          {"GET", "/api/v1/repos/#{@repo_id}/branches/#{@head_ref}"},
          fn conn ->
            :counters.add(counter, 1, 1)

            if :counters.get(counter, 1) == 1 do
              Plug.Conn.resp(conn, 404, ~s({"message":"branch does not exist"}))
            else
              Req.Test.json(conn, %{
                "name" => @head_ref,
                "commit" => Map.put(ours, "id", @head_sha)
              })
            end
          end
        )
        |> Map.put(
          {"POST", "/api/v1/repos/#{@repo_id}/branches"},
          jsonc(409, %{"message" => "The branch already exists."})
        )
        |> Map.delete({"POST", "/api/v1/repos/#{@repo_id}/contents"})

      stub(routes)

      assert {:ok, _cr} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())

      refute_received {:request, {"POST", "/api/v1/repos/#{@repo_id}/contents"}}
    end

    # Same race one step later: both runs saw the file absent and planned a
    # `create`; A landed first, so B's write returns file-exists 422. B must
    # re-read and recognise A's commit as the one it would have produced.
    test "a file-exists 422 reconciles instead of assuming conflict" do
      ours = %{
        "message" => "Automated change",
        "timestamp" => "2026-07-29T10:00:00Z",
        "author" => %{"name" => "Ezagent", "email" => "ezagent@invalid"},
        "committer" => %{"name" => "Ezagent", "email" => "ezagent@invalid"}
      }

      counter = :counters.new(1, [])

      routes =
        happy_path()
        |> Map.put(elem(file_is_ours(), 0), elem(file_is_ours(), 1))
        |> Map.put(
          {"GET", "/api/v1/repos/#{@repo_id}/branches/#{@head_ref}"},
          fn conn ->
            :counters.add(counter, 1, 1)

            # Read 1 is `ensure_head`'s single head_state — `ensure_commit` no
            # longer repeats it (that repeat was up to 100 extra content reads on
            # a resume). A lands between that read and B's POST, so only read 2,
            # the reconciliation after the 422, sees A's commit.
            if :counters.get(counter, 1) <= 1 do
              Req.Test.json(conn, %{"name" => @head_ref, "commit" => %{"id" => @base_sha}})
            else
              Req.Test.json(conn, %{
                "name" => @head_ref,
                "commit" => Map.put(ours, "id", @head_sha)
              })
            end
          end
        )
        |> Map.put(
          {"POST", "/api/v1/repos/#{@repo_id}/contents"},
          jsonc(422, %{"message" => "repository file already exists [path: docs/a.md]"})
        )

      stub(routes)

      assert {:ok, _cr} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())

      # Without this the test would pass by never reaching the write at all.
      assert_received {:request, {"POST", "/api/v1/repos/#{@repo_id}/contents"}}
    end

    # Regression: collapsing `ensure_head`'s two reads into one made it return a
    # hardcoded `:at_base` after a branch creation, which DISCARDED the 409
    # path's finding that the branch already carried this run's commit — so the
    # write ran again. `POST /contents` is not idempotent, so that is a real
    # duplicate commit, not a no-op.
    test "a 409 that reconciles to already-written does not write again" do
      ours = %{
        "message" => "Automated change",
        "timestamp" => "2026-07-29T18:00:00+08:00",
        "author" => %{"name" => "Ezagent", "email" => "ezagent@invalid"},
        "committer" => %{"name" => "Ezagent", "email" => "ezagent@invalid"}
      }

      counter = :counters.new(1, [])

      routes =
        happy_path()
        |> Map.put(elem(file_is_ours(), 0), elem(file_is_ours(), 1))
        |> Map.put(
          {"GET", "/api/v1/repos/#{@repo_id}/branches/#{@head_ref}"},
          fn conn ->
            :counters.add(counter, 1, 1)

            if :counters.get(counter, 1) == 1 do
              Plug.Conn.resp(conn, 404, ~s({"message":"branch does not exist"}))
            else
              Req.Test.json(conn, %{
                "name" => @head_ref,
                "commit" => Map.put(ours, "id", @head_sha)
              })
            end
          end
        )
        |> Map.put(
          {"POST", "/api/v1/repos/#{@repo_id}/branches"},
          jsonc(409, %{"message" => "The branch already exists."})
        )

      stub(routes)

      assert {:ok, _cr} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())

      refute_received {:request, {"POST", "/api/v1/repos/#{@repo_id}/contents"}}
    end

    # The reconciliation must not become a way to resume onto someone else's
    # branch: if the re-read shows a commit that is NOT ours, it is still a
    # conflict.
    test "reconciliation after a 409 still refuses a foreign commit" do
      foreign = %{
        "message" => "totally different",
        "timestamp" => "2020-01-01T00:00:00Z",
        "author" => %{"name" => "Someone", "email" => "other@invalid"},
        "committer" => %{"name" => "Someone", "email" => "other@invalid"}
      }

      counter = :counters.new(1, [])

      routes =
        happy_path()
        |> Map.put(
          {"GET", "/api/v1/repos/#{@repo_id}/branches/#{@head_ref}"},
          fn conn ->
            :counters.add(counter, 1, 1)

            if :counters.get(counter, 1) == 1 do
              Plug.Conn.resp(conn, 404, ~s({"message":"branch does not exist"}))
            else
              Req.Test.json(conn, %{
                "name" => @head_ref,
                "commit" => Map.put(foreign, "id", @head_sha)
              })
            end
          end
        )
        |> Map.put(
          {"POST", "/api/v1/repos/#{@repo_id}/branches"},
          jsonc(409, %{"message" => "The branch already exists."})
        )

      stub(routes)

      assert {:error, :head_ref_conflict} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())
    end
  end

  describe "path and error classification" do
    # `FileChange.valid_path?/1` admits `#`, `?` and `%`. Interpolated raw into
    # the URL they are parsed as fragment/query, so the GET reads a DIFFERENT
    # path (usually 404) -> the adapter plans a `create` -> Forgejo answers
    # file-exists 422 against the real path in the JSON body -> the run reports
    # a concurrency conflict for what is purely an encoding bug.
    test "a path containing URI-reserved characters is encoded in the read" do
      test_pid = self()
      {:ok, change} = FileChange.new(%{path: "docs/a?b#c.md", operation: :upsert, content: "x"})

      routes =
        happy_path()
        |> Map.delete({"GET", "/api/v1/repos/#{@repo_id}/contents/docs/a.md"})
        |> Map.put(
          {"GET", "/api/v1/repos/#{@repo_id}/contents/docs/a%3Fb%23c.md"},
          fn conn ->
            send(test_pid, :encoded_read)
            Plug.Conn.resp(conn, 404, ~s({"message":"object does not exist"}))
          end
        )

      stub(routes)

      assert {:ok, _cr} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), [change], request!())

      assert_received :encoded_read
    end

    # `blob_sha/3` also serves the WRITE path (`file_operations/2` reads each path
    # to choose create-vs-update), so the same discrimination protects a first
    # execution: writing a plain file over a submodule would otherwise plan an
    # `update` carrying that submodule's commit sha as if it were a blob sha.
    test "a submodule on the write path is refused before any write" do
      routes =
        happy_path()
        |> Map.put(
          {"GET", "/api/v1/repos/#{@repo_id}/contents/docs/a.md"},
          json(%{"type" => "submodule", "sha" => String.duplicate("9", 40)})
        )

      stub(routes)

      assert {:error, :invalid_file_change} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())

      refute_received {:request, {"POST", "/api/v1/repos/#{@repo_id}/contents"}}
    end

    # `sha_required` means the adapter built a malformed file operation (an
    # update without the blob sha). That is an INTERNAL construction error, not
    # a concurrent branch move, and design §8 gives it a distinct stable code so
    # the caller does not retry a request that can never succeed.
    test "sha_required is invalid_file_change, not head_ref_conflict" do
      routes =
        happy_path()
        |> Map.put(
          {"POST", "/api/v1/repos/#{@repo_id}/contents"},
          jsonc(422, %{"message" => "a SHA or commit ID must be provided in the request"})
        )

      stub(routes)

      assert {:error, :invalid_file_change} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())
    end

    # These two DO mean the state read a moment ago is stale.
    test "file_exists and branch_exists stay head_ref_conflict" do
      for message <- ["repository file already exists [path: docs/a.md]", "branch already exists"] do
        routes =
          happy_path()
          |> Map.put(
            {"POST", "/api/v1/repos/#{@repo_id}/contents"},
            jsonc(422, %{"message" => message})
          )

        stub(routes)

        assert {:error, :head_ref_conflict} =
                 ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())
      end
    end
  end

  describe "find-or-create across pages" do
    # `GET /pulls` has no head/base filter (findings §2.1), so the match is made
    # client-side over the open list. Reading only the first page turns "the PR
    # is on page 2" into "there is no PR" and opens a SECOND one -- which is
    # exactly the duplicate this whole find-or-create path exists to prevent.
    test "finds the existing PR when it is not on the first page" do
      target = %{
        "number" => 7,
        "html_url" => "https://#{@host}/#{@repo_id}/pulls/7",
        "state" => "open",
        "merged" => false,
        "head" => %{"ref" => @head_ref, "sha" => @head_sha},
        "base" => %{"ref" => "main"}
      }

      filler =
        for n <- 1..50 do
          %{
            "number" => 100 + n,
            "html_url" => "https://#{@host}/#{@repo_id}/pulls/#{100 + n}",
            "state" => "open",
            "head" => %{"ref" => "someone/else-#{n}"},
            "base" => %{"ref" => "main"}
          }
        end

      routes =
        happy_path()
        |> Map.put(
          {"GET", "/api/v1/repos/#{@repo_id}/pulls"},
          fn conn ->
            page =
              conn
              |> Plug.Conn.fetch_query_params()
              |> Map.fetch!(:query_params)
              |> Map.get("page", "1")
              |> String.to_integer()

            body = if page == 1, do: filler, else: if(page == 2, do: [target], else: [])
            # `Req.Test.json/2` directly, NOT the `json/1` helper: that helper
            # paginates on its own, which would zero out page 2 a second time.
            Req.Test.json(conn, body)
          end
        )
        |> Map.delete({"POST", "/api/v1/repos/#{@repo_id}/pulls"})

      stub(routes)

      assert {:ok, %{external_id: "7"}} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())

      refute_received {:request, {"POST", "/api/v1/repos/#{@repo_id}/pulls"}}
    end

    # The pagination work above refuses a TRUNCATED read because "we did not see
    # the whole list" is indistinguishable from "there is no match" and would
    # open a second PR. An entry we cannot READ is the same failure one level
    # down, and it was not covered: `exact_match?/2` answered `false` for a pull
    # whose `head.ref` was missing or whose shape was not a map, so an existing
    # PR that had drifted was filtered out, the list came back empty, and
    # find-or-create created a DUPLICATE on the provider.
    #
    # That is a wrong WRITE, not a misreport — the strongest reason this one had
    # to be fixed rather than filed.
    # One page of `entries`, then empty — the shape `all_pages/5` needs to stop.
    defp pulls_returning(entries) do
      happy_path()
      |> Map.put(
        {"GET", "/api/v1/repos/#{@repo_id}/pulls"},
        fn conn ->
          page =
            conn
            |> Plug.Conn.fetch_query_params()
            |> Map.fetch!(:query_params)
            |> Map.get("page", "1")

          Req.Test.json(conn, if(page == "1", do: entries, else: []))
        end
      )
    end

    test "refuses when a pull entry cannot be read, rather than opening a duplicate" do
      unreadable = [
        # `head` present but `ref` missing — the field most likely to drift.
        %{"number" => 5, "head" => %{"sha" => @head_sha}, "base" => %{"ref" => "main"}},
        # `head` is not a map at all.
        %{"number" => 5, "head" => "feature", "base" => %{"ref" => "main"}},
        # the entry itself is not a map.
        "not-a-pull"
      ]

      for entry <- unreadable do
        routes =
          happy_path()
          |> Map.put(
            {"GET", "/api/v1/repos/#{@repo_id}/pulls"},
            fn conn ->
              page =
                conn
                |> Plug.Conn.fetch_query_params()
                |> Map.fetch!(:query_params)
                |> Map.get("page", "1")

              Req.Test.json(conn, if(page == "1", do: [entry], else: []))
            end
          )

        stub(routes)

        assert {:error, :provider_response_unrecognized} =
                 ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!()),
               "expected refusal for #{inspect(entry)}"

        # The point of the whole test: no second pull request was opened.
        refute_received {:request, {"POST", "/api/v1/repos/#{@repo_id}/pulls"}}
      end
    end

    # An entry whose head ref is READABLE AND DIFFERENT is proven not to be ours,
    # so it must not block anything — even though its `base` is unreadable. The
    # earlier readable/unreadable split failed this: it needed BOTH refs, so
    # "demonstrably somebody else's" and "cannot tell" collapsed into one bucket
    # and the first one blocked the repository for no reason.
    test "an entry with a readable, different head does not block create" do
      other = %{
        "number" => 9,
        "head" => %{"ref" => "someone/else"},
        # base is unreadable — irrelevant, the head already settles it
        "base" => %{"sha" => @base_sha}
      }

      stub(pulls_returning([other]))

      assert {:ok, %Ezagent.DomainGit.ChangeRequest{}} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())

      # Asserted, not inferred from the returned id: the point is that the
      # create branch was REACHED, i.e. the unrelated entry blocked nothing.
      assert_received {:request, {"POST", "/api/v1/repos/#{@repo_id}/pulls"}}
    end

    # The counterpart, and the reason `{[single], _} -> reuse` was wrong: this
    # entry supplies OUR base and no head, so nothing in it proves it is not a
    # second pull request on the same head+base. The design's rule for that
    # state is exactly-one-or-fail, and with an opaque candidate present the
    # adapter cannot establish "exactly one" — reusing the readable one could
    # silently attach the whole workflow to the wrong review history.
    test "an opaque entry blocks reuse, because exactly-one cannot be established" do
      target = %{
        "number" => 7,
        "html_url" => "https://#{@host}/#{@repo_id}/pulls/7",
        "state" => "open",
        "merged" => false,
        "head" => %{"ref" => @head_ref, "sha" => @head_sha},
        "base" => %{"ref" => "main"}
      }

      opaque = %{"number" => 9, "head" => %{"sha" => @base_sha}, "base" => %{"ref" => "main"}}

      routes =
        [opaque, target]
        |> pulls_returning()
        |> Map.delete({"POST", "/api/v1/repos/#{@repo_id}/pulls"})

      stub(routes)

      assert {:error, :provider_response_unrecognized} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())

      refute_received {:request, {"POST", "/api/v1/repos/#{@repo_id}/pulls"}}
    end

    # `limit` is a REQUEST, not a guarantee: `max_response_items` is an instance
    # setting (50 on the probe instance, but configurable). On an instance that
    # caps lower, a FULL page comes back shorter than asked for — and treating
    # "shorter than requested" as "last page" then stops mid-list, which
    # re-creates the duplicate PR this pagination exists to prevent.
    test "keeps paging when the instance caps the page size below the request" do
      target = %{
        "number" => 7,
        "html_url" => "https://#{@host}/#{@repo_id}/pulls/7",
        "state" => "open",
        "merged" => false,
        "head" => %{"ref" => @head_ref, "sha" => @head_sha},
        "base" => %{"ref" => "main"}
      }

      # 20 per page regardless of the requested 50 — an instance with
      # max_response_items = 20.
      filler = fn n ->
        %{
          "number" => 100 + n,
          "html_url" => "https://#{@host}/#{@repo_id}/pulls/#{100 + n}",
          "state" => "open",
          "merged" => false,
          "head" => %{"ref" => "other/#{n}", "sha" => @base_sha},
          "base" => %{"ref" => "main"}
        }
      end

      routes =
        happy_path()
        |> Map.put(
          {"GET", "/api/v1/repos/#{@repo_id}/pulls"},
          fn conn ->
            page =
              conn
              |> Plug.Conn.fetch_query_params()
              |> Map.fetch!(:query_params)
              |> Map.get("page", "1")
              |> String.to_integer()

            body =
              case page do
                1 -> for n <- 1..20, do: filler.(n)
                2 -> [target]
                _ -> []
              end

            Req.Test.json(conn, body)
          end
        )
        |> Map.delete({"POST", "/api/v1/repos/#{@repo_id}/pulls"})

      stub(routes)

      assert {:ok, %{external_id: "7"}} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())

      refute_received {:request, {"POST", "/api/v1/repos/#{@repo_id}/pulls"}}
    end

    # Two exact matches must stay a conflict even when they straddle a page
    # boundary -- otherwise paging silently downgrades the ambiguity.
    test "two exact matches on different pages are still a conflict" do
      match = fn n ->
        %{
          "number" => n,
          "html_url" => "https://#{@host}/#{@repo_id}/pulls/#{n}",
          "state" => "open",
          "merged" => false,
          "head" => %{"ref" => @head_ref, "sha" => @head_sha},
          "base" => %{"ref" => "main"}
        }
      end

      page1 =
        [match.(7)] ++
          for(
            n <- 1..49,
            do: %{
              "number" => 200 + n,
              "html_url" => "https://#{@host}/#{@repo_id}/pulls/#{200 + n}",
              "state" => "open",
              "head" => %{"ref" => "other/#{n}"},
              "base" => %{"ref" => "main"}
            }
          )

      routes =
        happy_path()
        |> Map.put(
          {"GET", "/api/v1/repos/#{@repo_id}/pulls"},
          fn conn ->
            page =
              conn
              |> Plug.Conn.fetch_query_params()
              |> Map.fetch!(:query_params)
              |> Map.get("page", "1")
              |> String.to_integer()

            body = if page == 1, do: page1, else: if(page == 2, do: [match.(9)], else: [])
            Req.Test.json(conn, body)
          end
        )

      stub(routes)

      assert {:error, :change_request_conflict} =
               ForgejoAdapter.create_change_request(ctx(), repo!(), changes(), request!())
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
