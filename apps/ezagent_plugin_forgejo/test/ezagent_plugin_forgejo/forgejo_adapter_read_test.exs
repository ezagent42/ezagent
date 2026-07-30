defmodule EzagentPluginForgejo.ForgejoAdapterReadTest do
  @moduledoc """
  Slice F2 — the four read callbacks.

  These go through the real credential path (a stored connection resolved by
  `CredentialSource`) and a Req stub standing in for the instance, so the
  request the adapter actually sends is what gets asserted.
  """
  use ExUnit.Case, async: false

  alias Ezagent.DomainGit.{ChangeRequestId, CommitSha, OperationContext, RepositoryRef}
  alias Ezagent.ProviderConnection.Connection
  alias EzagentCore.Repo
  alias EzagentPluginForgejo.{ForgejoAdapter, ForgejoCredentialBackend}

  @stub :forgejo_adapter_read_test
  @ws "workspace://acme"
  @owner "entity://acme/user/dev"
  @host "code.hyprial.test"

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
      authorization_backend_ref: "auth-1",
      backend_pair_id: "pair-forgejo-v1",
      authorization_backend_id: "local-authorization-v1",
      credential_backend_id: "forgejo-credential-v1"
    })

    :ok
  end

  defp stub(fun) do
    Req.Test.stub(@stub, fun)
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

  defp ctx(overrides \\ %{}) do
    hash = String.duplicate("a", 64)

    {:ok, context} =
      OperationContext.new(
        Map.merge(
          %{
            task_access_uri: Ezagent.URI.new!("entity://acme/worker/gta_#{hash}"),
            caller_uri: Ezagent.URI.new!("entity://acme/agent/codex"),
            grantee_uri: Ezagent.URI.new!("entity://acme/agent/codex"),
            credential_owner_uri: Ezagent.URI.new!(@owner),
            idempotency_key: "read-1"
          },
          overrides
        )
      )

    context
  end

  defp repo!(overrides \\ %{}) do
    {:ok, ref} =
      RepositoryRef.new(
        Map.merge(
          %{
            repository_uri: Ezagent.URI.new!("resource://acme/git-repository/main"),
            provider_adapter: :forgejo,
            provider_host: @host,
            external_id: "gagameow/ezagent-forgejo-test",
            owner_path: "gagameow",
            base_ref: "main",
            visibility: :private
          },
          overrides
        )
      )

    ref
  end

  describe "resolve_repository/2" do
    test "confirms the repository against the instance" do
      stub(fn conn ->
        assert conn.request_path == "/api/v1/repos/gagameow/ezagent-forgejo-test"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["token at-live"]
        Req.Test.json(conn, %{"full_name" => "gagameow/ezagent-forgejo-test", "private" => true})
      end)

      assert {:ok, %RepositoryRef{external_id: "gagameow/ezagent-forgejo-test"}} =
               ForgejoAdapter.resolve_repository(ctx(), repo!())
    end

    test "a missing repository is repository_not_found" do
      stub(fn conn -> Plug.Conn.resp(conn, 404, ~s({"message":"not found"})) end)

      assert {:error, :repository_not_found} =
               ForgejoAdapter.resolve_repository(ctx(), repo!())
    end

    test "a forbidden repository is a read denial, not a missing repository" do
      stub(fn conn -> Plug.Conn.resp(conn, 403, ~s({"message":"forbidden"})) end)

      assert {:error, :repository_read_denied} =
               ForgejoAdapter.resolve_repository(ctx(), repo!())
    end

    # No connection for the credential owner means the account was never
    # connected -- distinct from the repository being absent.
    test "an unconnected credential owner fails before any HTTP call" do
      test_pid = self()

      stub(fn conn ->
        send(test_pid, :called_provider)
        Req.Test.json(conn, %{})
      end)

      other = ctx(%{credential_owner_uri: Ezagent.URI.new!("entity://acme/user/nobody")})

      assert {:error, :provider_account_not_connected} =
               ForgejoAdapter.resolve_repository(other, repo!())

      refute_received :called_provider
    end

    # Design §8.3: a 5xx keeps its status so an operator can tell 500 from 502,
    # and a transport failure is a different code entirely because the remote
    # state is unknown.
    test "a 5xx keeps its status" do
      stub(fn conn -> Plug.Conn.resp(conn, 503, "") end)

      assert {:error, {:provider_request_failed, :resolve_repository, 503}} =
               ForgejoAdapter.resolve_repository(ctx(), repo!())
    end

    test "a transport failure is reported with status 0" do
      stub(fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert {:error, {:provider_request_failed, :resolve_repository, 0}} =
               ForgejoAdapter.resolve_repository(ctx(), repo!())
    end
  end

  describe "read_change_request/3" do
    test "reads and normalizes a pull request" do
      stub(fn conn ->
        assert conn.request_path == "/api/v1/repos/gagameow/ezagent-forgejo-test/pulls/42"

        Req.Test.json(conn, %{
          "number" => 42,
          "html_url" => "https://code.hyprial.test/o/r/pulls/42",
          "state" => "open",
          "merged" => false,
          "head" => %{"ref" => "task/run-1", "sha" => String.duplicate("b", 40)},
          "base" => %{"ref" => "main"}
        })
      end)

      {:ok, id} = ChangeRequestId.new(%{external_id: "42"})

      assert {:ok, %{external_id: "42", state: :open}} =
               ForgejoAdapter.read_change_request(ctx(), repo!(), id)
    end

    test "a missing pull request is repository_not_found" do
      stub(fn conn -> Plug.Conn.resp(conn, 404, ~s({"message":"not found"})) end)
      {:ok, id} = ChangeRequestId.new(%{external_id: "999"})

      assert {:error, :repository_not_found} =
               ForgejoAdapter.read_change_request(ctx(), repo!(), id)
    end
  end

  describe "list_checks/3" do
    # The measured trap: `/statuses` returns the full re-run history (56 entries
    # across 17 contexts on one head). The combined `/status` endpoint returns
    # one per context, which is what a Check list must be.
    test "reads the COMBINED status endpoint, not the status history" do
      stub(fn conn ->
        assert conn.request_path ==
                 "/api/v1/repos/gagameow/ezagent-forgejo-test/commits/#{String.duplicate("c", 40)}/status"

        refute String.ends_with?(conn.request_path, "/statuses")

        Req.Test.json(conn, %{
          "state" => "failure",
          "statuses" => [
            %{"id" => 1, "context" => "ci / test", "status" => "failure", "target_url" => ""}
          ]
        })
      end)

      {:ok, sha} = CommitSha.new(%{value: String.duplicate("c", 40)})

      assert {:ok, [%{name: "ci / test", conclusion: :failed}]} =
               ForgejoAdapter.list_checks(ctx(), repo!(), sha)
    end

    test "no checks is an empty list, not a failure" do
      stub(fn conn -> Req.Test.json(conn, %{"state" => "pending", "statuses" => []}) end)
      {:ok, sha} = CommitSha.new(%{value: String.duplicate("c", 40)})

      assert {:ok, []} = ForgejoAdapter.list_checks(ctx(), repo!(), sha)
    end

    test "a denied checks read is checks_unavailable" do
      stub(fn conn -> Plug.Conn.resp(conn, 403, ~s({"message":"no"})) end)
      {:ok, sha} = CommitSha.new(%{value: String.duplicate("c", 40)})

      assert {:error, :checks_unavailable} = ForgejoAdapter.list_checks(ctx(), repo!(), sha)
    end
  end

  describe "list_reviews/3" do
    # Measured: the list mixes in REQUEST_REVIEW entries, which are requests
    # for a review rather than submitted reviews.
    test "keeps submitted reviews and drops review requests" do
      stub(fn conn ->
        assert conn.request_path == "/api/v1/repos/gagameow/ezagent-forgejo-test/pulls/42/reviews"

        Req.Test.json(conn, [
          %{
            "id" => 1,
            "state" => "APPROVED",
            "dismissed" => false,
            "user" => %{"login" => "alice"},
            "submitted_at" => "2026-07-29T10:00:00Z"
          },
          %{
            "id" => 2,
            "state" => "REQUEST_REVIEW",
            "dismissed" => false,
            "user" => %{"login" => "bob"}
          }
        ])
      end)

      {:ok, id} = ChangeRequestId.new(%{external_id: "42"})

      assert {:ok, [%{author_label: "alice", state: :approved}]} =
               ForgejoAdapter.list_reviews(ctx(), repo!(), id)
    end

    # `ListPullReviews` takes `page`/`limit` (target-instance swagger), so a
    # single unpaginated GET silently drops everything past the first page —
    # and the reviews it drops are the OLDEST, which is where an earlier
    # blocking `REQUEST_CHANGES` would sit.
    test "reads every page of reviews" do
      review = fn id, login ->
        %{
          "id" => id,
          "state" => "APPROVED",
          "dismissed" => false,
          "user" => %{"login" => login},
          "submitted_at" => "2026-07-29T10:00:00Z"
        }
      end

      stub(fn conn ->
        page =
          conn
          |> Plug.Conn.fetch_query_params()
          |> Map.fetch!(:query_params)
          |> Map.get("page", "1")
          |> String.to_integer()

        body =
          case page do
            1 -> for n <- 1..50, do: review.(n, "user#{n}")
            2 -> [review.(51, "last")]
            _ -> []
          end

        Req.Test.json(conn, body)
      end)

      {:ok, id} = ChangeRequestId.new(%{external_id: "42"})

      assert {:ok, reviews} = ForgejoAdapter.list_reviews(ctx(), repo!(), id)
      assert length(reviews) == 51
      assert Enum.any?(reviews, &(&1.author_label == "last"))
    end

    test "no reviews is an empty list, not a failure" do
      stub(fn conn -> Req.Test.json(conn, []) end)
      {:ok, id} = ChangeRequestId.new(%{external_id: "42"})

      assert {:ok, []} = ForgejoAdapter.list_reviews(ctx(), repo!(), id)
    end
  end

  describe "credential handling" do
    # Design §4.2: one fresh lease per callback, nothing cached across calls.
    # If the adapter cached, a revoked credential would keep working.
    test "each callback leases the credential again" do
      stub(fn conn ->
        Req.Test.json(conn, %{"full_name" => "gagameow/ezagent-forgejo-test", "private" => true})
      end)

      assert {:ok, _} = ForgejoAdapter.resolve_repository(ctx(), repo!())

      # Revoking between calls must take effect immediately.
      assert EzagentCore.Repo.aggregate(EzagentPluginForgejo.CredentialRecord, :count) > 0
      EzagentCore.Repo.delete_all(EzagentPluginForgejo.CredentialRecord)

      assert {:error, :credential_backend_unavailable} =
               ForgejoAdapter.resolve_repository(ctx(), repo!())
    end

    test "a successful result carries no trace of the token" do
      stub(fn conn ->
        Req.Test.json(conn, %{"full_name" => "gagameow/ezagent-forgejo-test", "private" => true})
      end)

      assert {:ok, result} = ForgejoAdapter.resolve_repository(ctx(), repo!())
      refute inspect(result) =~ "at-live"
    end
  end
end
