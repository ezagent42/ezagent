defmodule Ezagent.Security.GithubApiCommitTransportTest do
  use ExUnit.Case, async: true

  alias Ezagent.TestSupport.GithubGitDataPlan, as: Plan

  @sentinel "EZAGENT_SECRET_SENTINEL_DO_NOT_SHIP"
  @base_sha String.duplicate("a", 40)

  test "builds and locally interprets the Git Data change-request sequence" do
    assert {:ok, request_plan} = Plan.build(valid_changes(), valid_opts())

    assert Enum.map(request_plan, &{&1.method, &1.operation}) == [
             {:get, :base_ref},
             {:get, :base_commit},
             {:post, :blob},
             {:post, :tree},
             {:post, :commit},
             {:post, :ref},
             {:post, :pull}
           ]

    refute inspect(request_plan) =~ "authorization"
    refute inspect(request_plan) =~ @sentinel

    assert {:ok,
            %{
              change_request_id: 42,
              change_request_url: "https://github.example/pulls/42",
              head_sha: head_sha
            }} = Plan.interpret(request_plan, auth: @sentinel)

    assert byte_size(head_sha) == 40
  end

  test "rejects path traversal, symlinks, and submodules" do
    for change <- [
          %{path: "../secret", content: "x", kind: :regular},
          %{path: "/absolute", content: "x", kind: :regular},
          %{path: "safe//file", content: "x", kind: :regular},
          %{path: "safe\0file", content: "x", kind: :regular},
          %{path: <<"safe", 255>>, content: "x", kind: :regular},
          %{path: "binary", content: <<255>>, kind: :regular},
          %{path: "safe", content: "x", kind: :symlink},
          %{path: "safe", content: "x", kind: :submodule}
        ] do
      assert {:error, _reason} = Plan.build([change], valid_opts())
    end
  end

  test "enforces file count, per-file bytes, and total bytes" do
    assert {:error, :too_many_files} =
             Plan.build([regular("a"), regular("b")], valid_opts(max_files: 1))

    assert {:error, {:file_too_large, "a"}} =
             Plan.build([regular("a", "123")], valid_opts(max_file_bytes: 2))

    assert {:error, :total_bytes_exceeded} =
             Plan.build(
               [regular("a", "12"), regular("b", "34")],
               valid_opts(max_total_bytes: 3)
             )
  end

  test "rejects invalid coordinates and refs, and detects a changed base sha" do
    for overrides <- [
          [owner: "../other"],
          [repository: "repo/other"],
          [head_ref: "refs/heads/../../main"],
          [head_ref: "feature..lock"],
          [head_ref: "feature."],
          [head_ref: "feature/.hidden"]
        ] do
      assert {:error, _reason} = Plan.build(valid_changes(), valid_opts(overrides))
    end

    assert {:ok, request_plan} = Plan.build(valid_changes(), valid_opts())

    assert {:error, :base_sha_mismatch} =
             Plan.interpret(request_plan,
               auth: @sentinel,
               actual_base_sha: String.duplicate("b", 40)
             )
  end

  test "local replay is deterministic and partial failures are allowlisted and redacted" do
    assert {:ok, request_plan} = Plan.build(valid_changes(), valid_opts())

    assert {:ok, first} = Plan.interpret(request_plan, auth: @sentinel)
    assert {:ok, replay} = Plan.interpret(request_plan, auth: @sentinel)
    assert first == replay

    assert {:error, {:provider_request_failed, :commit, 502}} =
             error =
             Plan.interpret(request_plan,
               auth: @sentinel,
               fail_at: :commit,
               raw_response: %{
                 authorization: @sentinel,
                 body: "upstream internal response"
               }
             )

    refute inspect(error) =~ @sentinel
    refute inspect(error) =~ "upstream internal response"
    refute inspect(error) =~ "authorization"

    assert {:error, {:provider_request_failed, :unknown, 502}} =
             Plan.interpret(request_plan, auth: @sentinel, fail_at: %{token: @sentinel})
  end

  defp valid_changes, do: [regular("docs/demo.md", "demo\n")]

  defp regular(path, content \\ "x"), do: %{path: path, content: content, kind: :regular}

  defp valid_opts(overrides \\ []) do
    Keyword.merge(
      [
        owner: "ezagent42",
        repository: "ezagent",
        base_ref: "main",
        base_sha: @base_sha,
        head_ref: "ezagent/demo-probe",
        title: "Demo probe",
        body: "Sentinel-free change request",
        idempotency_key: "task-123-attempt-1"
      ],
      overrides
    )
  end
end
