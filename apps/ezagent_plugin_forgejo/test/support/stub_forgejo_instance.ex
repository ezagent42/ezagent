defmodule EzagentPluginForgejo.StubForgejoInstance do
  @moduledoc """
  A stateful in-memory Forgejo instance for local end-to-end tests.

  Unlike a per-request stub, this one KEEPS STATE: a branch created by one
  request is visible to the next, and a `POST /contents` actually advances the
  branch. That is the whole point — the property under test is that running the
  adapter twice produces **one** branch, **one** commit and **one** pull
  request, and a stateless stub cannot tell a second mutation from the first.

  It also mirrors the two measured behaviours the adapter must survive
  (`docs/superpowers/specs/2026-07-29-forgejo-api-probe-findings.md` §3):

    * `POST /contents` is **not** idempotent — every accepted call appends a
      commit and moves the branch, even when the content is unchanged;
    * a duplicate branch is `409` from `POST /branches` but `422` from
      `POST /contents`.

  Every mutating request is counted, so a test can assert "exactly one commit
  happened across two runs" rather than inferring it.
  """

  use Agent

  @type t :: pid()

  defstruct branches: %{},
            files: %{},
            pulls: [],
            statuses: %{},
            reviews: %{},
            counts: %{},
            next_pull: 7

  @doc "Starts an instance holding one repository whose base branch is at `base_sha`."
  @spec start_link(keyword()) :: {:ok, t()}
  def start_link(opts) do
    base_ref = Keyword.get(opts, :base_ref, "main")
    base_sha = Keyword.fetch!(opts, :base_sha)

    Agent.start_link(fn ->
      %__MODULE__{branches: %{base_ref => %{"id" => base_sha, "message" => "base"}}}
    end)
  end

  @doc "How many times a mutating endpoint was accepted."
  @spec count(t(), atom()) :: non_neg_integer()
  def count(instance, kind), do: Agent.get(instance, &Map.get(&1.counts, kind, 0))

  @doc "The commit a branch currently points at, or nil."
  @spec branch_sha(t(), String.t()) :: String.t() | nil
  def branch_sha(instance, ref),
    do: Agent.get(instance, &get_in(&1.branches, [ref, "id"]))

  @doc "Every pull request the instance holds."
  @spec pulls(t()) :: [map()]
  def pulls(instance), do: Agent.get(instance, & &1.pulls)

  @doc "Records a commit status, as a CI system would."
  @spec put_status(t(), String.t(), map()) :: :ok
  def put_status(instance, sha, status) do
    Agent.update(instance, fn state ->
      %{state | statuses: Map.update(state.statuses, sha, [status], &(&1 ++ [status]))}
    end)
  end

  @doc "Records a review entry, including the request-for-review shape."
  @spec put_review(t(), String.t(), map()) :: :ok
  def put_review(instance, number, review) do
    Agent.update(instance, fn state ->
      %{state | reviews: Map.update(state.reviews, number, [review], &(&1 ++ [review]))}
    end)
  end

  @doc "Returns the Req plug that serves this instance."
  @spec plug(t()) :: (Plug.Conn.t() -> Plug.Conn.t())
  def plug(instance) do
    fn conn ->
      {:ok, raw, conn} = read_body(conn)
      body = decode(raw)

      {status, payload} =
        Agent.get_and_update(instance, fn state ->
          route(state, conn.method, path_parts(conn), conn.query_params, body)
        end)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(payload))
    end
  end

  # ── routing ──────────────────────────────────────────────────────────

  # Paths arrive as ["api","v1","repos",owner,repo | rest]; only `rest` varies.
  defp path_parts(conn) do
    conn.request_path
    |> String.split("/", trim: true)
    |> Enum.drop(5)
  end

  # A branch ref may contain slashes -- `task/p4e/run-<hex>` is the shape
  # `DeterministicRef.derive/2` produces. Real Forgejo matches the remainder
  # greedily (verified: raw slashes and %2F both return 200), so a stub that
  # split on a fixed two segments would be LESS permissive than the instance it
  # stands in for, and would fail the adapter for a reason production never has.
  defp route(state, "GET", ["branches" | rest], _query, _body) when rest != [] do
    ref = Enum.join(rest, "/")

    case Map.get(state.branches, ref) do
      nil -> {{404, %{"message" => "branch does not exist [name: #{ref}]"}}, state}
      commit -> {{200, %{"name" => ref, "commit" => commit}}, state}
    end
  end

  defp route(state, "POST", ["branches"], _query, body) do
    name = body["new_branch_name"]
    from = body["old_ref_name"]

    cond do
      Map.has_key?(state.branches, name) ->
        # Measured: duplicate branch is 409 HERE, and 422 from POST /contents.
        {{409, %{"message" => "The branch already exists."}}, state}

      true ->
        commit = %{"id" => from, "message" => "base"}
        state = put_in(state.branches[name], commit)
        {{201, %{"name" => name, "commit" => commit}}, bump(state, :branches)}
    end
  end

  defp route(state, "GET", ["contents" | rest], query, _body) do
    path = Enum.join(rest, "/")
    ref = Map.get(query, "ref")

    case Map.get(state.files, {ref, path}) do
      nil -> {{404, %{"message" => "object does not exist [path: #{path}]"}}, state}
      file -> {{200, file}, state}
    end
  end

  defp route(state, "POST", ["contents"], _query, body) do
    branch = body["branch"]

    cond do
      # `new_branch` against an existing branch: 422 here, not 409 (measured).
      is_binary(body["new_branch"]) and Map.has_key?(state.branches, body["new_branch"]) ->
        {{422, %{"message" => "branch already exists [name: #{body["new_branch"]}]"}}, state}

      not Map.has_key?(state.branches, branch) ->
        {{404, %{"message" => "branch does not exist [name: #{branch}]"}}, state}

      conflicting_files?(state, branch, body["files"]) ->
        [path | _] = conflicting_paths(state, branch, body["files"])
        {{422, %{"message" => "repository file already exists [path: #{path}]"}}, state}

      true ->
        # NOT idempotent, deliberately: every accepted call appends a commit and
        # moves the branch, exactly as measured. An adapter that re-sends this
        # after a lost response stacks a second commit -- which is what the
        # double-execution assertions exist to catch.
        commit = commit_for(body)
        state = put_in(state.branches[branch], commit)
        state = Enum.reduce(body["files"], state, &apply_file(&2, branch, &1))
        {{201, %{"commit" => %{"sha" => commit["id"]}}}, bump(state, :contents)}
    end
  end

  defp route(state, "GET", ["pulls"], query, _body) do
    open? = Map.get(query, "state", "open") == "open"
    pulls = Enum.filter(state.pulls, &(not open? or &1["state"] == "open"))
    {{200, pulls}, state}
  end

  defp route(state, "POST", ["pulls"], _query, body) do
    number = state.next_pull

    pull = %{
      "number" => number,
      "html_url" => "https://stub.test/pulls/#{number}",
      "state" => "open",
      "merged" => false,
      "head" => %{"ref" => body["head"], "sha" => branch_id(state, body["head"])},
      "base" => %{"ref" => body["base"]}
    }

    state = %{state | pulls: state.pulls ++ [pull], next_pull: number + 1}
    {{201, pull}, bump(state, :pulls)}
  end

  defp route(state, "GET", ["pulls", number], _query, _body) do
    case Enum.find(state.pulls, &(to_string(&1["number"]) == number)) do
      nil -> {{404, %{"message" => "pull does not exist"}}, state}
      pull -> {{200, pull}, state}
    end
  end

  defp route(state, "GET", ["pulls", number, "reviews"], _query, _body),
    do: {{200, Map.get(state.reviews, number, [])}, state}

  defp route(state, "GET", ["commits", sha, "status"], _query, _body) do
    statuses = Map.get(state.statuses, sha, [])

    payload = %{
      "state" => if(statuses == [], do: "pending", else: List.last(statuses)["status"]),
      "total_count" => length(statuses),
      "statuses" => statuses
    }

    {{200, payload}, state}
  end

  defp route(state, "GET", ["repos", _owner, _repo], _query, _body),
    do: {{200, %{"full_name" => "stub/repo", "private" => true}}, state}

  defp route(state, method, parts, _query, _body),
    do: {{599, %{"message" => "unrouted #{method} /#{Enum.join(parts, "/")}"}}, state}

  # ── state helpers ────────────────────────────────────────────────────

  # The commit id is a digest of everything a real Forgejo commit is a function
  # of (parent, message, dates, file contents), so the SAME inputs against the
  # SAME parent reproduce the SAME id -- the property measured in findings §3.2
  # and the one a resume relies on.
  defp commit_for(body) do
    id =
      {body["branch"], body["message"], body["dates"], body["files"]}
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha, &1))
      |> Base.encode16(case: :lower)

    %{"id" => id, "message" => body["message"]}
  end

  defp apply_file(state, branch, file) do
    sha =
      :crypto.hash(:sha, file["content"] || "")
      |> Base.encode16(case: :lower)

    put_in(state.files[{branch, file["path"]}], %{
      "path" => file["path"],
      "sha" => sha,
      "content" => file["content"]
    })
  end

  # A `create` against a path that already exists on that branch is the 422 the
  # adapter must read as "the state I read a moment ago is stale".
  defp conflicting_paths(state, branch, files) do
    for %{"operation" => "create", "path" => path} <- files,
        Map.has_key?(state.files, {branch, path}),
        do: path
  end

  defp conflicting_files?(state, branch, files),
    do: conflicting_paths(state, branch, files) != []

  defp branch_id(state, ref), do: get_in(state.branches, [ref, "id"])
  defp bump(state, kind), do: %{state | counts: Map.update(state.counts, kind, 1, &(&1 + 1))}

  defp read_body(conn) do
    case conn.method do
      "GET" -> {:ok, "", Plug.Conn.fetch_query_params(conn)}
      _other -> Plug.Conn.read_body(Plug.Conn.fetch_query_params(conn))
    end
  end

  defp decode(""), do: %{}

  defp decode(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _other -> %{}
    end
  end
end
