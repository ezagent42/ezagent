defmodule Ezagent.TestSupport.GithubGitDataPlan do
  @moduledoc """
  Test-only pure request planner and local interpreter for a GitHub Git Data
  change request. It performs no HTTP and never accepts authentication in the
  generated plan.
  """

  @default_max_files 100
  @default_max_file_bytes 1_000_000
  @default_max_total_bytes 5_000_000
  @sha_pattern ~r/\A[0-9a-f]{40}\z/
  @ref_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._\/-]*\z/
  @coordinate_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @operations [:base_ref, :base_commit, :blob, :tree, :commit, :ref, :pull]

  @spec build([map()], keyword()) :: {:ok, [map()]} | {:error, term()}
  def build(changes, opts) when is_list(changes) and is_list(opts) do
    with :ok <- validate_required_opts(opts),
         :ok <- validate_coordinate(Keyword.fetch!(opts, :owner), :invalid_owner),
         :ok <-
           validate_coordinate(Keyword.fetch!(opts, :repository), :invalid_repository),
         :ok <- validate_ref(Keyword.fetch!(opts, :base_ref), :invalid_base_ref),
         :ok <- validate_ref(Keyword.fetch!(opts, :head_ref), :invalid_head_ref),
         :ok <- validate_sha(Keyword.fetch!(opts, :base_sha)),
         :ok <- validate_changes(changes, opts) do
      {:ok, request_plan(changes, opts)}
    end
  end

  @spec interpret([map()], keyword()) ::
          {:ok,
           %{
             change_request_id: pos_integer(),
             change_request_url: String.t(),
             head_sha: String.t()
           }}
          | {:error, term()}
  def interpret(request_plan, opts) when is_list(request_plan) and is_list(opts) do
    base_request = Enum.find(request_plan, &(&1.operation == :base_ref))
    actual_base_sha = Keyword.get(opts, :actual_base_sha, base_request.expected_sha)

    cond do
      actual_base_sha != base_request.expected_sha ->
        {:error, :base_sha_mismatch}

      fail_at = Keyword.get(opts, :fail_at) ->
        operation = if fail_at in @operations, do: fail_at, else: :unknown
        {:error, {:provider_request_failed, operation, 502}}

      true ->
        idempotency_key =
          request_plan
          |> Enum.find(&(&1.method == :post))
          |> Map.fetch!(:idempotency_key)

        head_sha = digest40("head:" <> idempotency_key)

        {:ok,
         %{
           change_request_id: 42,
           change_request_url: "https://github.example/pulls/42",
           head_sha: head_sha
         }}
    end
  end

  defp validate_required_opts(opts) do
    required = [
      :owner,
      :repository,
      :base_ref,
      :base_sha,
      :head_ref,
      :title,
      :body,
      :idempotency_key
    ]

    case Enum.find(required, &(not Keyword.has_key?(opts, &1))) do
      nil -> :ok
      key -> {:error, {:missing_option, key}}
    end
  end

  defp validate_ref(ref, error)
       when is_binary(ref) and ref != "" do
    segments = :binary.split(ref, "/", [:global])

    if Regex.match?(@ref_pattern, ref) and
         not String.starts_with?(ref, "refs/") and
         not String.ends_with?(ref, "/") and
         not String.ends_with?(ref, ".") and
         not String.contains?(ref, "//") and
         not String.contains?(ref, "..") and
         Enum.all?(segments, &valid_ref_segment?/1) do
      :ok
    else
      {:error, error}
    end
  end

  defp validate_ref(_ref, error), do: {:error, error}

  defp validate_coordinate(value, error) when is_binary(value) do
    if Regex.match?(@coordinate_pattern, value), do: :ok, else: {:error, error}
  end

  defp validate_coordinate(_value, error), do: {:error, error}

  defp valid_ref_segment?(segment) do
    segment not in ["", ".", ".."] and
      not String.starts_with?(segment, ".") and
      not String.ends_with?(segment, ".lock")
  end

  defp validate_sha(sha) when is_binary(sha) do
    if Regex.match?(@sha_pattern, sha), do: :ok, else: {:error, :invalid_base_sha}
  end

  defp validate_sha(_sha), do: {:error, :invalid_base_sha}

  defp validate_changes(changes, opts) do
    max_files = Keyword.get(opts, :max_files, @default_max_files)
    max_file_bytes = Keyword.get(opts, :max_file_bytes, @default_max_file_bytes)
    max_total_bytes = Keyword.get(opts, :max_total_bytes, @default_max_total_bytes)

    cond do
      changes == [] ->
        {:error, :no_changes}

      length(changes) > max_files ->
        {:error, :too_many_files}

      invalid = Enum.find(changes, &(not valid_regular_change?(&1))) ->
        {:error, change_error(invalid)}

      oversized = Enum.find(changes, &(byte_size(&1.content) > max_file_bytes)) ->
        {:error, {:file_too_large, oversized.path}}

      Enum.sum(Enum.map(changes, &byte_size(&1.content))) > max_total_bytes ->
        {:error, :total_bytes_exceeded}

      true ->
        :ok
    end
  end

  defp valid_regular_change?(%{path: path, content: content, kind: :regular})
       when is_binary(path) and is_binary(content) do
    valid_path?(path) and String.valid?(content)
  end

  defp valid_regular_change?(_change), do: false

  defp valid_path?(path) do
    segments = Path.split(path)

    String.valid?(path) and
      not control_byte?(path) and
      Path.type(path) == :relative and
      path != "" and
      not String.starts_with?(path, "/") and
      not String.ends_with?(path, "/") and
      not String.contains?(path, "//") and
      not String.contains?(path, "\\") and
      Enum.all?(segments, &(&1 not in ["", ".", "..", ".git"]))
  end

  defp control_byte?(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.any?(&(&1 < 32 or &1 == 127))
  end

  defp change_error(%{kind: kind}) when kind in [:symlink, :submodule],
    do: {:unsupported_change_kind, kind}

  defp change_error(%{path: path}), do: {:invalid_path, path}
  defp change_error(_change), do: :invalid_change

  defp request_plan(changes, opts) do
    owner = Keyword.fetch!(opts, :owner)
    repository = Keyword.fetch!(opts, :repository)
    base_ref = Keyword.fetch!(opts, :base_ref)
    base_sha = Keyword.fetch!(opts, :base_sha)
    head_ref = Keyword.fetch!(opts, :head_ref)
    idempotency_key = Keyword.fetch!(opts, :idempotency_key)
    root = "/repos/#{owner}/#{repository}"

    base_request = %{
      method: :get,
      operation: :base_ref,
      path: "#{root}/git/ref/heads/#{base_ref}",
      expected_sha: base_sha
    }

    base_commit_request = %{
      method: :get,
      operation: :base_commit,
      path: "#{root}/git/commits/#{base_sha}"
    }

    blob_requests =
      Enum.map(changes, fn change ->
        mutation(:blob, "#{root}/git/blobs", idempotency_key, %{
          content: change.content,
          encoding: "utf-8"
        })
      end)

    tree_entries =
      Enum.with_index(changes, fn change, index ->
        %{path: change.path, mode: "100644", type: "blob", blob_result: index}
      end)

    tail = [
      mutation(:tree, "#{root}/git/trees", idempotency_key, %{
        base_tree: {:result, :base_commit, :tree_sha},
        tree: tree_entries
      }),
      mutation(:commit, "#{root}/git/commits", idempotency_key, %{
        message: Keyword.fetch!(opts, :title),
        tree: {:result, :tree, :sha},
        parents: [base_sha]
      }),
      mutation(:ref, "#{root}/git/refs", idempotency_key, %{
        ref: "refs/heads/#{head_ref}",
        sha: {:result, :commit, :sha}
      }),
      mutation(:pull, "#{root}/pulls", idempotency_key, %{
        title: Keyword.fetch!(opts, :title),
        body: Keyword.fetch!(opts, :body),
        head: head_ref,
        base: base_ref
      })
    ]

    [base_request, base_commit_request] ++ blob_requests ++ tail
  end

  defp mutation(operation, path, idempotency_key, body) do
    %{
      method: :post,
      operation: operation,
      path: path,
      idempotency_key: idempotency_key,
      body: body
    }
  end

  defp digest40(value) do
    :sha
    |> :crypto.hash(value)
    |> Base.encode16(case: :lower)
  end
end
