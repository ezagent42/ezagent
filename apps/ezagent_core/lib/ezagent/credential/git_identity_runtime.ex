defmodule Ezagent.Credential.GitIdentityRuntime do
  @moduledoc """
  SSH 凭据 1b — the pure WRITE mechanism for a per-agent git identity.

  Given an agent URI and private-key bytes, materializes

      <GitIdentityDir.path(agent)>/id_ed25519   (0600)
      <GitIdentityDir.path(agent)>/known_hosts  (0644, copied from the node file)

  and returns the `GIT_SSH_COMMAND` env map the flavor merges into the agent
  subprocess env.

  **Knows nothing about Users, caps, or dispatch.** Deciding WHETHER an agent
  gets an identity, and WHOSE, is `Ezagent.Identity.AgentGitIdentity`'s job
  (domain tier — it reads identity-domain data).

  ## Why no atomic stage-and-swap

  `Ezagent.Credential.HomeRuntime.stage_and_swap/7` exists because the config
  dir has concurrent readers (a running subprocess) and a partially-copied dir
  is indistinguishable from a complete one. Neither applies here: this write
  happens on the spawn path BEFORE the subprocess starts, and there is exactly
  one writer per agent. A plain overwrite is correct — **do not** copy the
  staging machinery over here "for consistency".

  ## known_hosts

  Node-level, operator-provisioned, pointed at by
  `config :ezagent_core, :git_known_hosts_path`. Generate it with
  `mix ezagent.git.known_hosts`.

  Absent or unreadable → **fail loud**, and the private key is NOT left behind.
  The alternative (`StrictHostKeyChecking=no`) would silently accept any host
  key on first connect.

  ## Directory invariant (design §6.1)

  After `write/2` returns, the git-identity dir either holds EXACTLY the
  identity just written (`{:ok, _}`), or is gone entirely (any `{:error,
  _}`) — never a stale key from an earlier call. This is load-bearing, not
  cosmetic: it is what makes cap revocation take effect on the next spawn
  (§6.2). The orchestration layer calls `write/2` on every spawn; when a cap
  is revoked it simply stops calling `write/2` for that agent (materializing
  `{:ok, :none}` instead) and is responsible for wiping via `wipe/1` — but
  `write/2` failing here for an UNRELATED reason (e.g. known_hosts got
  unconfigured after a prior call had already written a key) must not let
  that prior key linger either. Two independent code reviews found this
  broken (see `GitIdentityRuntimeTest` for the regression coverage) — see
  design doc §6.1 for the incident.
  """

  require Logger

  alias Ezagent.Sandbox.GitIdentityDir

  @key_basename "id_ed25519"
  @known_hosts_basename "known_hosts"
  @key_mode 0o600
  @known_hosts_mode 0o644

  @doc """
  Materialize the given SSH private key for `agent_uri` and return the env map.

  Returns `{:ok, %{"GIT_SSH_COMMAND" => cmd}}`, or one of:

    * `{:error, :known_hosts_unconfigured}` — no `:git_known_hosts_path` set
    * `{:error, {:known_hosts_unreadable, {path, reason}}}` — set but unreadable
    * `{:error, {:git_identity_dir_allocate_failed, reason}}`
    * `{:error, {:git_identity_write_failed, {basename, reason}}}`

  Every non-`:ok` outcome leaves the git-identity dir empty — see the
  moduledoc "Directory invariant" section.

  **Never logs or returns the key material.**
  """
  @spec write(URI.t(), String.t()) :: {:ok, %{String.t() => String.t()}} | {:error, term()}
  def write(%URI{} = agent_uri, key_pem) when is_binary(key_pem) do
    # 整支终审 K2 — design §6.1: "write/2 一进来就先清目录". Without this,
    # a SUCCESSFUL write only ever overwrites the two fixed basenames
    # (`id_ed25519` / `known_hosts`) — any THIRD file already sitting in the
    # dir (an earlier version's basename, a leftover from an interrupted
    # write) survives every subsequent successful write forever. The `else`
    # wipe below only fires on FAILURE, which never covered the success
    # path. codex 复审真跑复现: pre-seed a `stale-private-key` file, call
    # `write/2` successfully, and the stale file was still there. This
    # makes the directory invariant unconditional: the dir holds EXACTLY
    # what this call wrote, from the very first line of the function, not
    # just on the error paths.
    :ok = wipe(agent_uri)

    # known_hosts BEFORE the key: everything that CAN fail must fail before
    # the private key touches disk (design §6.1 point 2 — a missing/unreadable
    # node known_hosts file, or an allocate failure, must not leave a key
    # behind). And ANY failure below wipes the whole dir again (point 3)
    # through this ONE `else` clause rather than each branch remembering to
    # — that single choke point is what makes a STALE key from an earlier
    # successful `write/2` call disappear when THIS call fails early (e.g.
    # known_hosts got unconfigured after a prior write already succeeded).
    # Redundant with the leading wipe above only when THIS call fails before
    # writing anything; it is NOT redundant when this call fails AFTER
    # `GitIdentityDir.allocate/1` has already written a partial file (e.g.
    # known_hosts written, then the key write fails) — that partial residue
    # still needs clearing.
    with {:ok, known_hosts} <- read_known_hosts(),
         {:ok, dir} <- GitIdentityDir.allocate(agent_uri),
         :ok <-
           write_file(
             Path.join(dir, @known_hosts_basename),
             known_hosts,
             @known_hosts_mode
           ),
         :ok <- write_file(Path.join(dir, @key_basename), key_pem, @key_mode) do
      {:ok, %{"GIT_SSH_COMMAND" => ssh_command(dir)}}
    else
      {:error, _reason} = error ->
        wipe(agent_uri)
        error
    end
  end

  @doc "The configured node-level known_hosts path, or `nil` when unset."
  @spec known_hosts_path() :: String.t() | nil
  def known_hosts_path do
    case Application.get_env(:ezagent_core, :git_known_hosts_path) do
      path when is_binary(path) and path != "" -> path
      _ -> nil
    end
  end

  @doc "Remove an agent's git-identity dir. Idempotent; best-effort."
  @spec wipe(URI.t()) :: :ok
  def wipe(%URI{} = agent_uri) do
    dir = GitIdentityDir.path(agent_uri)

    case File.rm_rf(dir) do
      {:ok, _} ->
        :ok

      {:error, reason, path} ->
        Logger.warning(
          "git-identity wipe failed for #{URI.to_string(agent_uri)} at #{path}: " <>
            inspect(reason)
        )

        :ok
    end
  rescue
    # A non-agent URI raises ArgumentError in `path/1`'s own segment checks;
    # an unsafe segment (e.g. a `..` name — `Ezagent.URI.segment!/1` does not
    # reject it) instead raises RuntimeError from inside `path/1` when
    # `FsResolver.resolve/2` itself rejects the resolved URI (findings G4 —
    # same shape issue as `GitIdentityDir.safe_to_destroy?/2`). Cleanup must
    # never crash a destroy path, so both are rescued here.
    _e in [ArgumentError, RuntimeError] -> :ok
  end

  # ── internals ──────────────────────────────────────────────────────────────

  # Every option here defends against a DEFAULT that silently uses the wrong
  # identity or trusts the wrong host — see the moduledoc of each test in
  # `GitIdentityRuntimeTest` for the concrete consequence of dropping one.
  #
  # Paths are shell-quoted, not just interpolated: git hands `GIT_SSH_COMMAND`
  # to a shell, not exec/argv, so an unquoted path is subject to word
  # splitting and expansion. `EZAGENT_HOME` (`Ezagent.Home.home/0`) is read
  # straight from the environment with no space/character restriction, and
  # `Ezagent.URI.segment!/1` accepts anything except "" and "/" in an agent
  # name — including `$(...)` — so an unquoted path here is the one place in
  # the codebase where a config value with a space, or an agent name with
  # `$(...)`, turns into either a broken `ssh` invocation or shell command
  # substitution (findings G2; memory `feedback-gate-targets-accidents-not-attackers`
  # — this defends the default path, not against an attacker).
  defp ssh_command(dir) do
    # Local names deliberately distinct from the public `known_hosts_path/0`
    # (the node-level SOURCE config path) — these are the per-agent
    # DESTINATION paths inside `dir`, a different thing entirely.
    key_dest = shell_quote(Path.join(dir, @key_basename))
    known_hosts_dest = shell_quote(Path.join(dir, @known_hosts_basename))

    Enum.join(
      [
        "ssh",
        "-i #{key_dest}",
        "-o IdentitiesOnly=yes",
        "-o IdentityAgent=none",
        "-o UserKnownHostsFile=#{known_hosts_dest}",
        "-o StrictHostKeyChecking=yes"
      ],
      " "
    )
  end

  # POSIX single-quote a shell word: wrap in `'...'`, and for each embedded
  # `'` close the quote, emit an escaped literal quote, reopen the quote.
  # There is no in-quote escape character inside single quotes, so this
  # close/escape/reopen dance is the standard way to include one.
  @spec shell_quote(String.t()) :: String.t()
  defp shell_quote(str) do
    "'" <> String.replace(str, "'", "'\\''") <> "'"
  end

  defp read_known_hosts do
    case known_hosts_path() do
      nil ->
        {:error, :known_hosts_unconfigured}

      path ->
        case File.read(path) do
          {:ok, content} -> {:ok, content}
          {:error, reason} -> {:error, {:known_hosts_unreadable, {path, reason}}}
        end
    end
  end

  # chmod BEFORE the content lands would still leave a 0644 window on create,
  # so write then chmod; the containing dir is already 0700, which is the real
  # boundary.
  defp write_file(path, content, mode) do
    with :ok <- File.write(path, content),
         :ok <- File.chmod(path, mode) do
      :ok
    else
      # NEVER interpolate `content` — it may be the private key.
      {:error, reason} -> {:error, {:git_identity_write_failed, {Path.basename(path), reason}}}
    end
  end
end
