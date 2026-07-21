defmodule EzagentPluginGithub.GitHubCredentialBackend do
  @moduledoc """
  CredentialBackend implementation for GitHub credentials.

  ## Lifecycle (TDD phase)

  This is a minimal in-memory implementation backed by the **Process dictionary**
  for the TDD phase. Credentials are encrypted via `GitHubTokenStore` before
  storage using a fixed 32-byte key generated at module load time.

  Expected production replacements:
    * Process dictionary -> ETS table (per-node lifecycle) or a dedicated
      `GenServer` (persistent storage)
    * Fixed module-level key -> per-deployment key from `Application.get_env`
      or an external key-management service

  ## Callback contract

  Implements `Ezagent.ProviderConnection.CredentialBackend` behaviour.
  """

  @behaviour Ezagent.ProviderConnection.CredentialBackend

  alias EzagentPluginGithub.GitHubTokenStore

  @key :crypto.strong_rand_bytes(32)

  @impl true
  def store(command) do
    {:write_only_handoff, token} = command.credential_material

    ref =
      "github-credential-#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"

    encrypted = GitHubTokenStore.encrypt(token, @key)
    Process.put({:github_token, ref}, {encrypted, 1})
    {:ok, %{credential_ref: ref, credential_version: 1}}
  end

  @impl true
  def replace(command) do
    ref = command.credential_ref

    case Process.get({:github_token, ref}) do
      {_encrypted, version}
      when is_integer(version) and version == command.expected_credential_version ->
        {:write_only_handoff, new_token} = command.credential_material
        new_encrypted = GitHubTokenStore.encrypt(new_token, @key)
        new_version = version + 1
        Process.put({:github_token, ref}, {new_encrypted, new_version})
        {:ok, %{credential_ref: ref, credential_version: new_version}}

      {_encrypted, _version} ->
        {:error, :stale_version}

      nil ->
        {:error, :credential_conflict}
    end
  end

  @impl true
  def status(command) do
    case Process.get({:github_token, command.credential_ref}) do
      nil ->
        {:error, :credential_conflict}

      {_encrypted, version} ->
        {:ok, %{credential_ref: command.credential_ref, credential_version: version}}
    end
  end

  @impl true
  def lease_for_operation(_command), do: {:error, :backend_unavailable}

  @impl true
  def consume_lease(_command), do: :ok

  @impl true
  def begin_refresh_exchange(_command), do: {:error, :backend_unavailable}

  @impl true
  def consume_refresh_exchange(_command), do: {:error, :backend_unavailable}

  @impl true
  def revoke(command) do
    Process.delete({:github_token, command.credential_ref})
    :ok
  end
end
