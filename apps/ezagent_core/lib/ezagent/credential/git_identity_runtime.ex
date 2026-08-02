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
    * `{:error, {:known_hosts_unreadable, reason}}` — set but unreadable
    * `{:error, {:git_identity_dir_allocate_failed, reason}}`
    * `{:error, {:git_identity_write_failed, reason}}`

  **Never logs or returns the key material.**
  """
  @spec write(URI.t(), String.t()) :: {:ok, %{String.t() => String.t()}} | {:error, term()}
  def write(%URI{} = agent_uri, key_pem) when is_binary(key_pem) do
    # known_hosts FIRST: a missing node file must not leave a private key on disk.
    with {:ok, known_hosts} <- read_known_hosts(),
         {:ok, dir} <- GitIdentityDir.allocate(agent_uri),
         :ok <- write_file(Path.join(dir, @key_basename), key_pem, @key_mode),
         :ok <-
           write_file(
             Path.join(dir, @known_hosts_basename),
             known_hosts,
             @known_hosts_mode
           ) do
      {:ok, %{"GIT_SSH_COMMAND" => ssh_command(dir)}}
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
    # A non-agent URI raises in `path/1`. Cleanup must never crash a destroy path.
    ArgumentError -> :ok
  end

  # ── internals ──────────────────────────────────────────────────────────────

  # Every option here defends against a DEFAULT that silently uses the wrong
  # identity or trusts the wrong host — see the moduledoc of each test in
  # `GitIdentityRuntimeTest` for the concrete consequence of dropping one.
  defp ssh_command(dir) do
    Enum.join(
      [
        "ssh",
        "-i #{Path.join(dir, @key_basename)}",
        "-o IdentitiesOnly=yes",
        "-o IdentityAgent=none",
        "-o UserKnownHostsFile=#{Path.join(dir, @known_hosts_basename)}",
        "-o StrictHostKeyChecking=yes"
      ],
      " "
    )
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
