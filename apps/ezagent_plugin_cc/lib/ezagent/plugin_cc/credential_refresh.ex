defmodule EzagentPluginCc.CredentialRefresh do
  @moduledoc """
  #17 PR-E (④, TEST/E2E ONLY) — provision valid claude OAuth credentials into an agent's
  config home WITHOUT a human `/login`, so the 传话游戏 E2E is self-sufficient.

  Given a SOURCE `.credentials.json` (Allen 2026-06-04: `~/.claude` IS the test-dedicated
  login), this:

    1. takes an OS-level (cross-BEAM) exclusive lock on the source so concurrent E2E runs
       can't double-rotate the single-use refresh token;
    2. if the source's `accessToken` is expired, refreshes via the claude OAuth token
       endpoint (`refresh_token` grant) and **atomically writes the rotated tokens back to
       the source** (keeping `~/.claude` valid for the next run);
    3. copies the (now-valid) credential file into the agent's config home (chmod 600).

  Non-expired source → step 2 is skipped (just copy). The HTTP call and the clock are
  injectable (`opts`) so tests never hit the network or rotate a real token.

  NOT for production runtime — production users log in interactively (`claude /login`).
  """

  require Logger

  @cred_relpath ".credentials.json"
  # claude-code's public OAuth client id (refresh-token grant).
  @client_id "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  @token_endpoint "https://console.anthropic.com/api/oauth/token"
  # refresh slightly BEFORE expiry to avoid a race where the token dies mid-spawn.
  @expiry_skew_ms 60_000

  @doc """
  Ensure `home_dir` has a valid `.credentials.json`, sourced+refreshed from `source_path`.

  opts:
    * `:http_post`  — `fn(url, content_type, body) -> {:ok, status, resp_body} | {:error, term}`
      (default: `:httpc`-based). Injected by tests.
    * `:now_ms`     — current epoch ms (default `System.os_time(:millisecond)`). For tests.
    * `:client_id`  — OAuth client id (default the claude-code public id).
    * `:lock_timeout_ms` — max wait for the source lock (default 10_000).
  """
  @spec provision(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def provision(source_path, home_dir, opts \\ [])
      when is_binary(source_path) and is_binary(home_dir) do
    with_source_lock(source_path, opts, fn ->
      with {:ok, cred} <- read_cred(source_path),
           {:ok, fresh_cred} <- maybe_refresh(cred, source_path, opts) do
        copy_into_home(fresh_cred, home_dir)
      end
    end)
  end

  # --- refresh decision --------------------------------------------------

  defp maybe_refresh(%{"claudeAiOauth" => oauth} = cred, source_path, opts) do
    now = Keyword.get(opts, :now_ms, System.os_time(:millisecond))

    if expired?(oauth, now) do
      do_refresh(cred, oauth, source_path, opts)
    else
      {:ok, cred}
    end
  end

  defp maybe_refresh(cred, _source_path, _opts) do
    # No recognizable OAuth blob — copy as-is (e.g. an API-key shaped cred); the agent's
    # own startup will surface any auth failure (PR-C).
    {:ok, cred}
  end

  # Expired iff there is an `expiresAt` (epoch ms) at/before now (+ skew). An ABSENT
  # `expiresAt` is treated as "can't tell" → not refreshed (copy as-is).
  defp expired?(%{"expiresAt" => exp}, now) when is_integer(exp), do: exp <= now + @expiry_skew_ms
  defp expired?(_oauth, _now), do: false

  defp do_refresh(cred, oauth, source_path, opts) do
    case Map.get(oauth, "refreshToken") do
      rt when is_binary(rt) and rt != "" ->
        with {:ok, new_oauth} <- request_refresh(rt, opts) do
          merged = %{cred | "claudeAiOauth" => Map.merge(oauth, new_oauth)}
          # atomic write-back so the source stays a valid login for the next run.
          with :ok <- atomic_write(source_path, merged) do
            {:ok, merged}
          end
        end

      _ ->
        {:error, :source_missing_refresh_token}
    end
  end

  # --- OAuth refresh request --------------------------------------------

  defp request_refresh(refresh_token, opts) do
    client_id = Keyword.get(opts, :client_id, @client_id)
    now = Keyword.get(opts, :now_ms, System.os_time(:millisecond))

    body =
      Jason.encode!(%{
        "grant_type" => "refresh_token",
        "refresh_token" => refresh_token,
        "client_id" => client_id
      })

    http_post = Keyword.get(opts, :http_post, &default_http_post/3)

    case http_post.(@token_endpoint, "application/json", body) do
      {:ok, status, resp_body} when status in 200..299 ->
        parse_refresh_response(resp_body, now)

      {:ok, status, resp_body} ->
        {:error, {:refresh_http_status, status, truncate(resp_body)}}

      {:error, reason} ->
        {:error, {:refresh_http_failed, reason}}
    end
  end

  defp parse_refresh_response(resp_body, now) do
    case Jason.decode(resp_body) do
      {:ok, %{"access_token" => at} = m} when is_binary(at) ->
        oauth =
          %{"accessToken" => at}
          |> put_if(m, "refresh_token", "refreshToken")
          |> put_expiry(m, now)

        {:ok, oauth}

      {:ok, other} ->
        {:error, {:refresh_response_unexpected, truncate(inspect(other))}}

      {:error, reason} ->
        {:error, {:refresh_response_undecodable, reason}}
    end
  end

  defp put_if(acc, src, src_key, dst_key) do
    case Map.get(src, src_key) do
      v when is_binary(v) and v != "" -> Map.put(acc, dst_key, v)
      _ -> acc
    end
  end

  defp put_expiry(acc, %{"expires_in" => secs}, now) when is_integer(secs),
    do: Map.put(acc, "expiresAt", now + secs * 1000)

  defp put_expiry(acc, _m, _now), do: acc

  defp default_http_post(url, content_type, body) do
    request = {String.to_charlist(url), [], String.to_charlist(content_type), body}

    case :httpc.request(:post, request, [{:timeout, 10_000}, {:connect_timeout, 5_000}], []) do
      {:ok, {{_http, status, _reason}, _headers, resp_body}} ->
        {:ok, status, IO.iodata_to_binary(resp_body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- file IO ----------------------------------------------------------

  defp read_cred(source_path) do
    with {:ok, raw} <- File.read(source_path),
         {:ok, json} <- Jason.decode(raw) do
      {:ok, json}
    else
      {:error, :enoent} -> {:error, {:source_not_found, source_path}}
      {:error, %Jason.DecodeError{}} -> {:error, {:source_undecodable, source_path}}
      {:error, reason} -> {:error, {:source_read_failed, reason}}
    end
  end

  defp atomic_write(path, cred) do
    tmp = path <> ".tmp-#{System.unique_integer([:positive])}"
    encoded = Jason.encode!(cred, pretty: true)

    with :ok <- File.write(tmp, encoded),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      err ->
        _ = File.rm(tmp)
        {:error, {:atomic_write_failed, err}}
    end
  end

  defp copy_into_home(cred, home_dir) do
    with :ok <- File.mkdir_p(home_dir),
         dst = Path.join(home_dir, @cred_relpath),
         :ok <- File.write(dst, Jason.encode!(cred, pretty: true)),
         :ok <- File.chmod(dst, 0o600) do
      :ok
    else
      err -> {:error, {:copy_into_home_failed, err}}
    end
  end

  # --- cross-BEAM lock (exclusive lock-file create + bounded retry) ------

  defp with_source_lock(source_path, opts, fun) do
    lock_path = source_path <> ".refresh.lock"
    timeout = Keyword.get(opts, :lock_timeout_ms, 10_000)
    deadline = System.monotonic_time(:millisecond) + timeout

    case acquire_lock(lock_path, deadline) do
      :ok ->
        try do
          fun.()
        after
          _ = File.rm(lock_path)
        end

      {:error, :timeout} ->
        {:error, {:cred_refresh_lock_timeout, lock_path}}

      {:error, reason} ->
        # e.g. the source's parent dir doesn't exist (:enoent) — surface the real cause
        # (a missing source) instead of crashing on an unmatched case.
        if File.exists?(source_path),
          do: {:error, {:cred_refresh_lock_failed, reason}},
          else: {:error, {:source_not_found, source_path}}
    end
  end

  defp acquire_lock(lock_path, deadline) do
    case File.open(lock_path, [:write, :exclusive]) do
      {:ok, io} ->
        File.close(io)
        :ok

      {:error, :eexist} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(50)
          acquire_lock(lock_path, deadline)
        else
          {:error, :timeout}
        end

      {:error, reason} ->
        {:error, {:lock_open_failed, reason}}
    end
  end

  defp truncate(s) when is_binary(s), do: String.slice(s, 0, 200)
  defp truncate(s), do: s |> inspect() |> String.slice(0, 200)
end
