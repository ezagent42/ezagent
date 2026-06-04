defmodule EzagentPluginCodex.CredentialRefresh do
  @moduledoc """
  #21 PR-2b (④, TEST/E2E ONLY) — provision a codex agent's CODEX_HOME from a durable
  source, reproducing the FULL `credential_relpaths` set so the dockerized E2E can run
  without a human `codex login`.

  Codex differs from cc in two ways the design accounts for:

    * **A directory, not one file.** `Ezagent.PluginCodex.Template.CodexAgent.credential_relpaths/0`
      is `["auth.json", "config.toml"]`. The layer excludes BOTH (secrets never cached),
      so this provisioner must reproduce BOTH — `auth.json` (OAuth tokens) refreshed/copied
      and `config.toml` (static config) copied — or a restored CODEX_HOME is incomplete.

    * **No explicit `expiresAt`.** `auth.json` records `last_refresh` and the codex CLI
      self-refreshes the access token at runtime via the refresh token. So a *recent*
      source is copied as-is (the CLI handles the access-token refresh); only an
      implausibly-stale source (refresh token likely dead) triggers an OAuth refresh
      here — and ONLY if an `:http_post` is configured. With no refresh configured a stale
      source FAILS LOUD (`{:error, :codex_source_stale}` → re-`codex login` / re-seed)
      rather than silently copying a dead token (`feedback_let_it_crash_no_workarounds`).

  The OAuth POST and the clock are injectable so tests never hit the network or touch a
  real `~/.codex`. The source lock is **crash-recoverable** (a stale lease is stolen) so a
  killed run can't brick later runs. NOT for production runtime — production users
  `codex login` interactively.
  """

  require Logger

  @relpaths ["auth.json", "config.toml"]
  @auth_relpath "auth.json"
  # A source not refreshed within this window is treated as stale (refresh token likely
  # dead). Override with `:max_age_ms`.
  @default_max_age_ms 25 * 24 * 60 * 60 * 1000
  @default_lease_ms 30_000
  # Placeholder OAuth token endpoint — only used if a real `:http_post`/`:token_endpoint`
  # is configured (the common path is a recent source → copy, no refresh).
  @token_endpoint "https://auth.openai.com/oauth/token"

  @doc """
  Ensure `home_dir` (an agent CODEX_HOME) holds the full credential set sourced from
  `source_dir`.

  opts:
    * `:http_post` — `fn(url, content_type, body) -> {:ok, status, body} | {:error, term}`.
      If absent, NO refresh is attempted (a stale source errors).
    * `:now_ms` — current epoch ms (default `System.os_time(:millisecond)`).
    * `:max_age_ms` — staleness threshold (default 25d).
    * `:token_endpoint` — OAuth endpoint (default the codex/OpenAI one).
    * `:lock_lease_ms` — stale-lock lease (default 30_000) for crash recovery.
    * `:lock_timeout_ms` — max wait for the lock (default 10_000).
  """
  @spec provision(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def provision(source_dir, home_dir, opts \\ [])
      when is_binary(source_dir) and is_binary(home_dir) do
    with_source_lock(source_dir, opts, fn ->
      with {:ok, auth} <- read_auth(source_dir),
           {:ok, _fresh} <- maybe_refresh(auth, source_dir, opts),
           :ok <- copy_set(source_dir, home_dir) do
        :ok
      end
    end)
  end

  @doc """
  The crash-recoverable lock file path for a source dir (exposed for tests).

  INSIDE the source dir (codex r-review) so concurrent containers sharing the same
  mounted credential volume (e.g. `cred_codex:/cred/codex`) share the one lock — a
  sibling-of-dir path would NOT be shared by the volume mount.
  """
  @spec lock_path(String.t()) :: String.t()
  def lock_path(source_dir), do: Path.join(source_dir, ".codex-refresh.lock")

  # --- refresh decision --------------------------------------------------

  defp maybe_refresh(auth, source_dir, opts) do
    now = Keyword.get(opts, :now_ms, System.os_time(:millisecond))
    max_age = Keyword.get(opts, :max_age_ms, @default_max_age_ms)

    if token_stale?(auth, now, max_age) do
      case Keyword.get(opts, :http_post) do
        nil -> {:error, :codex_source_stale}
        _fun -> do_refresh(auth, source_dir, opts)
      end
    else
      {:ok, auth}
    end
  end

  # Stale iff `last_refresh` is absent/unparseable OR older than max_age.
  defp token_stale?(%{"last_refresh" => lr}, now, max_age) when is_binary(lr) do
    case DateTime.from_iso8601(lr) do
      {:ok, dt, _} -> now - DateTime.to_unix(dt, :millisecond) > max_age
      _ -> true
    end
  end

  defp token_stale?(_auth, _now, _max_age), do: true

  defp do_refresh(auth, source_dir, opts) do
    now = Keyword.get(opts, :now_ms, System.os_time(:millisecond))
    tokens = Map.get(auth, "tokens", %{})

    case Map.get(tokens, "refresh_token") do
      rt when is_binary(rt) and rt != "" ->
        with {:ok, new_tokens} <- request_refresh(rt, opts) do
          merged =
            auth
            |> Map.put("tokens", Map.merge(tokens, new_tokens))
            |> Map.put("last_refresh", iso(now))

          with :ok <- atomic_write(Path.join(source_dir, @auth_relpath), merged) do
            {:ok, merged}
          end
        end

      _ ->
        {:error, :source_missing_refresh_token}
    end
  end

  # --- OAuth refresh request --------------------------------------------

  defp request_refresh(refresh_token, opts) do
    endpoint = Keyword.get(opts, :token_endpoint, @token_endpoint)
    http_post = Keyword.fetch!(opts, :http_post)
    body = Jason.encode!(%{"grant_type" => "refresh_token", "refresh_token" => refresh_token})

    case http_post.(endpoint, "application/json", body) do
      {:ok, status, resp} when status in 200..299 -> parse_refresh_response(resp)
      {:ok, status, resp} -> {:error, {:refresh_http_status, status, truncate(resp)}}
      {:error, reason} -> {:error, {:refresh_http_failed, reason}}
    end
  end

  defp parse_refresh_response(resp) do
    case Jason.decode(resp) do
      {:ok, %{"access_token" => at} = m} when is_binary(at) ->
        tokens =
          %{"access_token" => at}
          |> put_if(m, "refresh_token")
          |> put_if(m, "id_token")

        {:ok, tokens}

      {:ok, other} ->
        {:error, {:refresh_response_unexpected, truncate(inspect(other))}}

      {:error, reason} ->
        {:error, {:refresh_response_undecodable, reason}}
    end
  end

  defp put_if(acc, src, key) do
    case Map.get(src, key) do
      v when is_binary(v) and v != "" -> Map.put(acc, key, v)
      _ -> acc
    end
  end

  # --- file IO ----------------------------------------------------------

  defp read_auth(source_dir) do
    path = Path.join(source_dir, @auth_relpath)

    with {:ok, raw} <- File.read(path),
         {:ok, json} <- Jason.decode(raw) do
      {:ok, json}
    else
      {:error, :enoent} -> {:error, {:source_not_found, path}}
      {:error, %Jason.DecodeError{}} -> {:error, {:source_undecodable, path}}
      {:error, reason} -> {:error, {:source_read_failed, reason}}
    end
  end

  # Copy EVERY declared relpath; FAIL LOUD if the source is missing one (an incomplete
  # CODEX_HOME would start codex with defaults/missing config).
  defp copy_set(source_dir, home_dir) do
    with :ok <- File.mkdir_p(home_dir) do
      Enum.reduce_while(@relpaths, :ok, fn rel, _ ->
        sp = Path.join(source_dir, rel)
        dp = Path.join(home_dir, rel)

        cond do
          not File.regular?(sp) ->
            {:halt, {:error, {:source_missing_relpath, rel}}}

          true ->
            case write_private(dp, File.read!(sp)) do
              :ok -> {:cont, :ok}
              {:error, err} -> {:halt, {:error, {:copy_failed, rel, err}}}
            end
        end
      end)
    end
  end

  defp atomic_write(path, map) do
    case write_private(path, Jason.encode!(map, pretty: true)) do
      :ok -> :ok
      {:error, err} -> {:error, {:atomic_write_failed, err}}
    end
  end

  # Write through a private temp (chmod 0600 BEFORE content) then atomic rename, so a
  # credential file is never group/world-readable even briefly.
  defp write_private(path, content) do
    tmp = path <> ".tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.touch(tmp),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.write(tmp, content),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      err ->
        _ = File.rm(tmp)
        {:error, err}
    end
  end

  # --- crash-recoverable lease lock -------------------------------------

  # Crash-recoverable, OWNER-FENCED lease lock (codex r-review):
  #   * acquire writes a UNIQUE owner token into the lock file (exclusive create).
  #   * a lock whose mtime is older than the lease is from a crashed run → stolen.
  #   * release removes the lock ONLY if we still own it — a steal hands the lock to
  #     another owner, and we must never delete THEIR lock (the un-fenced bug).
  # `provision/3`'s critical section (one HTTP refresh + a couple file writes) is far
  # shorter than the default lease, so a live holder is not stolen in practice; the
  # fenced release makes a stale-steal safe even if it ever happened.
  defp with_source_lock(source_dir, opts, fun) do
    lock = lock_path(source_dir)
    lease = Keyword.get(opts, :lock_lease_ms, @default_lease_ms)
    timeout = Keyword.get(opts, :lock_timeout_ms, 10_000)
    owner = mint_owner()
    deadline = System.monotonic_time(:millisecond) + timeout

    case acquire(lock, owner, lease, deadline) do
      :ok ->
        try do
          fun.()
        after
          release(lock, owner)
        end

      {:error, :timeout} ->
        {:error, {:cred_refresh_lock_timeout, lock}}

      {:error, reason} ->
        # e.g. the source dir doesn't exist — surface the real cause.
        if File.dir?(source_dir),
          do: {:error, {:cred_refresh_lock_failed, reason}},
          else: {:error, {:source_not_found, source_dir}}
    end
  end

  defp mint_owner do
    "#{:erlang.phash2({node(), self()})}-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
  end

  defp acquire(lock, owner, lease, deadline) do
    case File.open(lock, [:write, :exclusive]) do
      {:ok, io} ->
        IO.write(io, owner)
        File.close(io)
        :ok

      {:error, :eexist} ->
        cond do
          lock_stale?(lock, lease) ->
            _ = File.rm(lock)
            acquire(lock, owner, lease, deadline)

          System.monotonic_time(:millisecond) < deadline ->
            Process.sleep(50)
            acquire(lock, owner, lease, deadline)

          true ->
            {:error, :timeout}
        end

      {:error, reason} ->
        {:error, {:lock_open_failed, reason}}
    end
  end

  # Release ONLY if we still own the lock (a stale-steal may have handed it to another
  # owner; deleting theirs would reintroduce the double-rotation race).
  defp release(lock, owner) do
    case File.read(lock) do
      {:ok, ^owner} -> _ = File.rm(lock)
      _ -> :ok
    end
  end

  # A lock whose mtime is older than the lease is from a crashed run → steal it.
  defp lock_stale?(lock, lease_ms) do
    case File.stat(lock, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> System.os_time(:second) - mtime > div(lease_ms, 1000)
      _ -> false
    end
  end

  defp iso(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

  defp truncate(s) when is_binary(s), do: String.slice(s, 0, 200)
  defp truncate(s), do: s |> inspect() |> String.slice(0, 200)
end
