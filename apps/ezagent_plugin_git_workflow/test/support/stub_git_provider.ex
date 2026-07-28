defmodule EzagentPluginGitWorkflow.StubGitProvider do
  @moduledoc """
  A STATEFUL stand-in for the GitHub REST API, reached the way production
  reaches it: through `EzagentPluginGithub.GitHubAdapter`'s documented
  `:adapter_req_opts` injection point, as a plain 1-arity Plug function
  (`Req.Steps.run_plug/1` accepts one — see `call_plug/2`).

  ## Why a hand-written server rather than `Req.Test`

  Two reasons, and the second is the one that matters.

  1. `ezagent_plugin_git_workflow` must not depend on the GitHub plugin
     (design §3.2; `architecture_test.exs` "no GitHub, Kanban, or socialware
     plugin dependency"), and `:req` reaches this app only through that
     plugin. Naming `Req.Test` here compiles to a "module is not available"
     warning, which `mix precommit`'s `--warnings-as-errors` turns into a
     build failure. `Plug.Conn` and `Jason` ARE on this app's path, so a
     plain plug function is the shape that fits.

  2. `Req.Test.expect/3` is an ORDERED, single-use queue — a script of
     answers, not a provider. Design §8 asks for "one deterministic ref /
     one commit / one PR after two complete passes", which is a claim about
     PROVIDER STATE, and §6.2's crash windows are precisely the cases where
     the second pass must take a DIFFERENT route through the API than the
     first. A script cannot express "the ref already exists because you
     created it two minutes ago"; a server can, and this one does:

       * blobs, trees and commits are CONTENT-ADDRESSED (`sha/2`), so
         re-creating one returns the same sha and creates no second object —
         which is exactly how GitHub behaves and exactly what makes design
         §6.1's deterministic-commit amendment observable;
       * `POST git/refs` on an existing ref answers 422, as GitHub does;
       * `PATCH git/refs/heads/…` with `force: false` succeeds only as a
         fast-forward — the update is refused with 422 when the current
         target is not an ancestor of the new one;
       * the PR search matches on exact head+base+state, and creating a
         second PR for a head+base pair that already has an open one is
         refused.

  ## The request log is the point

  Every request is appended to `log/1` with its method, path, resulting
  status, whether it MUTATED provider state, and what (if anything) it
  CREATED. Design §8's "第二次允许 fresh-read，但没有重复 mutation" cannot be
  checked by inspecting the end state — that cannot tell "created once" from
  "created twice, the second was a no-op". Counting what the provider
  RECEIVED can.

  `authorization/1` is recorded as a CLASSIFICATION (`:installation_token` /
  `:app_jwt` / `:other` / `:none`), never as the raw header, so the log
  itself can be inspected in a failure message without becoming the leak the
  test is trying to disprove.

  ## Fault injection

  `fail_next/2` arms one matching request to answer with a chosen status.
  `mode: :before` (the default) refuses without touching provider state;
  `mode: :after` performs the effect and THEN answers with the failure —
  "the mutation happened, the receipt was lost", which is the only way to
  reach design §6.2's third crash window from outside.
  """

  use GenServer

  # ---------------------------------------------------------------------------
  # Client
  # ---------------------------------------------------------------------------

  @doc """
  Starts a provider whose repository already holds `base_ref` at `base_sha`.

  Options:

    * `:repo` — the `owner/name` external id (required);
    * `:base_ref` / `:base_sha` / `:base_tree_sha` — the seeded base commit;
    * `:token` — the installation token this provider mints (required, and
      deliberately distinctive so a leak test can search for it);
    * `:checks` / `:reviews` — the raw JSON maps the observation reads return.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "The 1-arity plug `:adapter_req_opts` carries; runs in the CALLER's process."
  @spec plug(pid()) :: (Plug.Conn.t() -> Plug.Conn.t())
  def plug(server) when is_pid(server) do
    fn %Plug.Conn{} = conn ->
      request = %{
        method: conn.method,
        path: conn.request_path,
        query: conn.query_params,
        body: conn.body_params,
        authorization: authorization_class(conn, GenServer.call(server, :token))
      }

      {status, body} = GenServer.call(server, {:request, request})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode_to_iodata!(body))
    end
  end

  @doc "Every request served since the last `reset_log/1`, oldest first."
  @spec log(pid()) :: [map()]
  def log(server), do: GenServer.call(server, :log)

  @doc "Drops the request log. Provider STATE (refs, objects, PRs) is untouched."
  @spec reset_log(pid()) :: :ok
  def reset_log(server), do: GenServer.call(server, :reset_log)

  @doc "Arms one failure. See the moduledoc for `:mode`."
  @spec fail_next(pid(), keyword()) :: :ok
  def fail_next(server, opts), do: GenServer.call(server, {:fail_next, opts})

  @doc "A snapshot of provider state — refs, objects and pull requests."
  @spec state(pid()) :: map()
  def state(server), do: GenServer.call(server, :state)

  @doc """
  Plants a ref pointing at a commit this provider did not build for the
  workflow — the "someone else's branch is sitting on my name" case.
  """
  @spec plant_ref(pid(), String.t(), keyword()) :: {:ok, String.t()}
  def plant_ref(server, ref, opts), do: GenServer.call(server, {:plant_ref, ref, opts})

  @doc """
  Replaces what the observation reads answer with.

  Two consecutive ticks that would return identical answers cannot show
  whether a snapshot came from the earlier tick or the later one — which is
  the exact question design §6.2's fifth crash window asks. Changing the
  answer in between makes the two ticks distinguishable in the row.
  """
  @spec set_observations(pid(), keyword()) :: :ok
  def set_observations(server, opts), do: GenServer.call(server, {:set_observations, opts})

  @doc """
  Points `ref` at an EXISTING commit without creating anything.

  The one shape `plant_ref/3` cannot express: a ref sitting at the base
  commit. There is no commit of its own to build, which is exactly why the
  adapter has no provenance to check there (its KNOWN LIMITATION).
  """
  @spec set_ref(pid(), String.t(), String.t()) :: :ok
  def set_ref(server, ref, sha), do: GenServer.call(server, {:set_ref, ref, sha})

  @doc "Requests that CHANGED provider state (or tried to), oldest first."
  @spec mutating(pid()) :: [map()]
  def mutating(server), do: Enum.filter(log(server), & &1.mutating)

  @doc "How many requests in the log match `method` and end with `suffix`."
  @spec count(pid(), String.t(), String.t()) :: non_neg_integer()
  def count(server, method, suffix) do
    server
    |> log()
    |> Enum.count(&(&1.method == method and String.ends_with?(&1.path, suffix)))
  end

  # ---------------------------------------------------------------------------
  # Server
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    repo = Keyword.fetch!(opts, :repo)
    base_sha = Keyword.fetch!(opts, :base_sha)
    base_tree_sha = Keyword.fetch!(opts, :base_tree_sha)

    {:ok,
     %{
       repo: repo,
       installation_id: 5150,
       token: Keyword.fetch!(opts, :token),
       refs: %{Keyword.fetch!(opts, :base_ref) => base_sha},
       commits: %{
         base_sha => %{"sha" => base_sha, "tree" => %{"sha" => base_tree_sha}, "parents" => []}
       },
       trees: %{base_tree_sha => :seeded},
       blobs: %{},
       pulls: [],
       next_number: 4200,
       checks: Keyword.get(opts, :checks, []),
       reviews: Keyword.get(opts, :reviews, []),
       log: [],
       faults: []
     }}
  end

  @impl true
  def handle_call(:token, _from, state), do: {:reply, state.token, state}
  def handle_call(:log, _from, state), do: {:reply, Enum.reverse(state.log), state}
  def handle_call(:reset_log, _from, state), do: {:reply, :ok, %{state | log: []}}

  def handle_call(:state, _from, state) do
    snapshot = Map.take(state, [:refs, :commits, :trees, :blobs, :pulls])
    {:reply, snapshot, state}
  end

  def handle_call({:set_observations, opts}, _from, state) do
    state =
      state
      |> Map.put(:checks, Keyword.get(opts, :checks, state.checks))
      |> Map.put(:reviews, Keyword.get(opts, :reviews, state.reviews))

    {:reply, :ok, state}
  end

  def handle_call({:fail_next, opts}, _from, state) do
    fault = %{
      method: Keyword.fetch!(opts, :method),
      suffix: Keyword.fetch!(opts, :suffix),
      status: Keyword.fetch!(opts, :status),
      mode: Keyword.get(opts, :mode, :before),
      body: Keyword.get(opts, :body, %{"message" => "stub failure"})
    }

    {:reply, :ok, %{state | faults: state.faults ++ [fault]}}
  end

  def handle_call({:set_ref, ref, sha}, _from, state),
    do: {:reply, :ok, %{state | refs: Map.put(state.refs, ref, sha)}}

  def handle_call({:plant_ref, ref, opts}, _from, state) do
    tree_sha = sha("tree", [Keyword.fetch!(opts, :marker)])

    commit_sha =
      sha("commit", ["planted", tree_sha, Keyword.fetch!(opts, :parent)])

    commit = %{
      "sha" => commit_sha,
      "tree" => %{"sha" => tree_sha},
      "parents" => [%{"sha" => Keyword.fetch!(opts, :parent)}]
    }

    state = %{
      state
      | refs: Map.put(state.refs, ref, commit_sha),
        commits: Map.put(state.commits, commit_sha, commit),
        trees: Map.put(state.trees, tree_sha, :planted)
    }

    {:reply, {:ok, commit_sha}, state}
  end

  def handle_call({:request, request}, _from, state) do
    {{status, body, created, mutating}, state} = serve(request, state)

    entry = %{
      method: request.method,
      path: request.path,
      query: request.query,
      body: request.body,
      authorization: request.authorization,
      status: status,
      created: created,
      mutating: mutating
    }

    {:reply, {status, body}, %{state | log: [entry | state.log]}}
  end

  # ---------------------------------------------------------------------------
  # Faults run BEFORE routing, so a `:before` fault costs the provider nothing
  # ---------------------------------------------------------------------------

  defp serve(request, state) do
    case take_fault(request, state) do
      {nil, state} ->
        route(request, state)

      {%{mode: :before} = fault, state} ->
        {{fault.status, fault.body, nil, false}, state}

      {%{mode: :after} = fault, state} ->
        # The effect lands, the answer does not — design §6.2's "PR POST
        # 成功但 receipt 丢失". `created`/`mutating` still describe what
        # really happened, because that is what the retry has to reconcile
        # against.
        {{_status, _body, created, mutating}, state} = route(request, state)
        {{fault.status, fault.body, created, mutating}, state}
    end
  end

  defp take_fault(request, state) do
    case Enum.split_while(
           state.faults,
           &(&1.method != request.method or not String.ends_with?(request.path, &1.suffix))
         ) do
      {_before, []} -> {nil, state}
      {before, [fault | rest]} -> {fault, %{state | faults: before ++ rest}}
    end
  end

  # ---------------------------------------------------------------------------
  # Routes
  # ---------------------------------------------------------------------------

  defp route(%{method: "GET", path: path} = request, %{repo: repo} = state) do
    case repo_path(path, repo) do
      "/installation" ->
        read(%{"id" => state.installation_id}, state)

      "/git/ref/heads/" <> ref ->
        case Map.fetch(state.refs, ref) do
          {:ok, sha} -> read(%{"object" => %{"sha" => sha}}, state)
          :error -> not_found(state)
        end

      "/git/commits/" <> sha ->
        case Map.fetch(state.commits, sha) do
          {:ok, commit} -> read(commit, state)
          :error -> not_found(state)
        end

      "/pulls" ->
        read(matching_pulls(request.query, state), state)

      "/commits/" <> rest ->
        checks_for(rest, state)

      "/pulls/" <> rest ->
        pull_read(rest, state)

      _other ->
        not_found(state)
    end
  end

  defp route(%{method: "POST", path: "/app/installations/" <> rest} = request, state) do
    if rest == "#{state.installation_id}/access_tokens" do
      mint(request.body, state)
    else
      not_found(state)
    end
  end

  defp route(%{method: "POST", path: path} = request, %{repo: repo} = state) do
    case repo_path(path, repo) do
      "/git/blobs" -> create_blob(request.body, state)
      "/git/trees" -> create_tree(request.body, state)
      "/git/commits" -> create_commit(request.body, state)
      "/git/refs" -> create_ref(request.body, state)
      "/pulls" -> create_pull(request.body, state)
      _other -> not_found(state)
    end
  end

  defp route(%{method: "PATCH", path: path} = request, %{repo: repo} = state) do
    case repo_path(path, repo) do
      "/git/refs/heads/" <> ref -> advance_ref(ref, request.body, state)
      _other -> not_found(state)
    end
  end

  defp route(_request, state), do: not_found(state)

  defp repo_path(path, repo) do
    prefix = "/repos/" <> repo

    if String.starts_with?(path, prefix),
      do: String.replace_prefix(path, prefix, ""),
      else: path
  end

  # ── Token mint ────────────────────────────────────────────────────────────
  #
  # `GitHubInstallation.validate_scope/3` refuses anything wider than what it
  # asked for, so the response ECHOES the requested permissions rather than
  # naming a fixed set: a stub that answered a fixed map would fail every
  # callback whose profile differs, and one that answered a WIDER map would
  # make the scope check untestable.

  defp mint(body, state) do
    response = %{
      "token" => state.token,
      "expires_at" => DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601(),
      "repository_selection" => "selected",
      "repositories" => [%{"full_name" => state.repo}],
      "permissions" => body["permissions"]
    }

    {{201, response, nil, false}, state}
  end

  # ── Git data ──────────────────────────────────────────────────────────────

  defp create_blob(body, state) do
    blob_sha = sha("blob", [body["encoding"], body["content"]])
    fresh = not Map.has_key?(state.blobs, blob_sha)

    {{201, %{"sha" => blob_sha}, created(fresh, {:blob, blob_sha}), fresh},
     %{state | blobs: Map.put(state.blobs, blob_sha, body["content"])}}
  end

  defp create_tree(body, state) do
    entries = Enum.map(body["tree"] || [], &[&1["path"], &1["mode"], &1["type"], &1["sha"]])
    tree_sha = sha("tree", [body["base_tree"] | List.flatten(entries)])
    fresh = not Map.has_key?(state.trees, tree_sha)

    {{201, %{"sha" => tree_sha}, created(fresh, {:tree, tree_sha}), fresh},
     %{state | trees: Map.put(state.trees, tree_sha, entries)}}
  end

  # Content-addressed over EVERY field GitHub hashes, `author`/`committer`
  # dates included. That is what makes design §6.1's 2026-07-27 amendment
  # observable: a retry that re-read the clock would land on a different sha
  # here, and the "one effective remote commit" assertion would go red.
  defp create_commit(body, state) do
    parents = body["parents"] || []
    author = body["author"] || %{}
    committer = body["committer"] || %{}

    commit_sha =
      sha("commit", [
        body["message"],
        body["tree"],
        Enum.join(parents, ","),
        author["name"],
        author["email"],
        author["date"],
        committer["name"],
        committer["email"],
        committer["date"]
      ])

    fresh = not Map.has_key?(state.commits, commit_sha)

    commit = %{
      "sha" => commit_sha,
      "tree" => %{"sha" => body["tree"]},
      "parents" => Enum.map(parents, &%{"sha" => &1})
    }

    {{201, %{"sha" => commit_sha}, created(fresh, {:commit, commit_sha}), fresh},
     %{state | commits: Map.put(state.commits, commit_sha, commit)}}
  end

  defp created(true, what), do: what
  defp created(false, _what), do: nil

  defp create_ref(body, state) do
    "refs/heads/" <> ref = body["ref"]

    if Map.has_key?(state.refs, ref) do
      # GitHub's answer to creating a ref that exists. The adapter
      # disambiguates it by re-reading (design §6.2).
      {{422, %{"message" => "Reference already exists"}, nil, false}, state}
    else
      {{201, %{"ref" => body["ref"], "object" => %{"sha" => body["sha"]}}, {:ref, ref}, true},
       %{state | refs: Map.put(state.refs, ref, body["sha"])}}
    end
  end

  # `force: false` is a fast-forward-only update. Refusing a non-fast-forward
  # with 422 is what turns a foreign ref into `:head_ref_conflict` instead of
  # a silent overwrite — and it is the only reason this stub can prove the
  # adapter never force-pushes.
  defp advance_ref(ref, body, state) do
    current = Map.get(state.refs, ref)

    cond do
      is_nil(current) ->
        not_found(state)

      body["force"] == true or ancestor?(current, body["sha"], state) ->
        {{200, %{"ref" => "refs/heads/" <> ref, "object" => %{"sha" => body["sha"]}},
          {:ref_advance, ref}, true}, %{state | refs: Map.put(state.refs, ref, body["sha"])}}

      true ->
        {{422, %{"message" => "Update is not a fast forward"}, nil, false}, state}
    end
  end

  defp ancestor?(candidate, candidate, _state), do: true

  defp ancestor?(candidate, sha, state) do
    case Map.fetch(state.commits, sha) do
      {:ok, %{"parents" => parents}} ->
        Enum.any?(parents, &ancestor?(candidate, &1["sha"], state))

      :error ->
        false
    end
  end

  # ── Pull requests ─────────────────────────────────────────────────────────

  defp matching_pulls(query, state) do
    head = query["head"]
    base = query["base"]
    pr_state = query["state"]

    state.pulls
    |> Enum.filter(fn pull ->
      qualified_head(pull, state) == head and pull["base"]["ref"] == base and
        pull["state"] == pr_state
    end)
    |> Enum.map(&refresh_head_sha(&1, state))
  end

  defp qualified_head(pull, state) do
    [owner | _rest] = String.split(state.repo, "/")
    owner <> ":" <> pull["head"]["ref"]
  end

  # The PR's head sha follows its ref, exactly as a real PR does — so an
  # observation tick that read the STORED sha instead of the fresh one would
  # be asking about a commit the PR has moved off.
  defp refresh_head_sha(pull, state) do
    case Map.fetch(state.refs, pull["head"]["ref"]) do
      {:ok, sha} -> put_in(pull, ["head", "sha"], sha)
      :error -> pull
    end
  end

  defp create_pull(body, state) do
    duplicate? =
      Enum.any?(state.pulls, &(&1["head"]["ref"] == body["head"] and &1["state"] == "open"))

    if duplicate? do
      {{422, %{"message" => "A pull request already exists"}, nil, false}, state}
    else
      number = state.next_number

      pull = %{
        "number" => number,
        "html_url" => "https://git.example.test/#{state.repo}/pull/#{number}",
        "state" => "open",
        "merged" => false,
        "title" => body["title"],
        "body" => body["body"],
        "head" => %{"ref" => body["head"], "sha" => Map.get(state.refs, body["head"])},
        "base" => %{"ref" => body["base"]}
      }

      {{201, pull, {:pull, number}, true},
       %{state | pulls: state.pulls ++ [pull], next_number: number + 1}}
    end
  end

  defp pull_read(rest, state) do
    case String.split(rest, "/") do
      [number] ->
        single_pull(number, state, &read(&1, state))

      [number, "reviews"] ->
        single_pull(number, state, fn _pull -> read(state.reviews, state) end)

      _other ->
        not_found(state)
    end
  end

  defp single_pull(number, state, found) do
    case Enum.find(state.pulls, &(to_string(&1["number"]) == number)) do
      nil -> not_found(state)
      pull -> found.(refresh_head_sha(pull, state))
    end
  end

  defp checks_for(rest, state) do
    case String.split(rest, "/") do
      [_sha, "check-runs"] ->
        read(%{"total_count" => length(state.checks), "check_runs" => state.checks}, state)

      _other ->
        not_found(state)
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp read(body, state), do: {{200, body, nil, false}, state}
  defp not_found(state), do: {{404, %{"message" => "Not Found"}, nil, false}, state}

  defp sha(kind, parts) do
    input =
      Enum.map_join([kind | parts], <<0>>, fn
        nil -> ""
        value when is_binary(value) -> value
        value -> inspect(value)
      end)

    :sha256 |> :crypto.hash(input) |> Base.encode16(case: :lower) |> binary_part(0, 40)
  end

  # A CLASSIFICATION, never the header itself — see the moduledoc.
  defp authorization_class(conn, token) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      [] -> :none
      ["Bearer " <> presented] -> if presented == token, do: :installation_token, else: :app_jwt
      [_other] -> :other
    end
  end
end
