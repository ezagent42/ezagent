defmodule EzagentPluginGithub.GitHubCredentialBackend do
  @moduledoc """
  CredentialBackend implementation for GitHub credentials.

  ## Lifecycle

  Credentials are stored in an ETS table (`:github_credential_tokens`) and
  encrypted via `GitHubTokenStore` using AES-256-GCM before storage. The
  encryption key is read from application config (`:ezagent_plugin_github,
  :token_encryption_key`) with a module-load-time generated fallback for
  development.

  The ETS table is created by `start_link/1` and must be started as a
  supervised process in the application's children list.

  ## Callback contract

  Implements `Ezagent.ProviderConnection.CredentialBackend` behaviour.
  """

  @behaviour Ezagent.ProviderConnection.CredentialBackend

  alias EzagentPluginGithub.GitHubTokenStore

  @table_name :github_credential_tokens

  # Fallback key — only usable within a single VM session. Production deployments
  # MUST configure a stable key via `:ezagent_plugin_github, :token_encryption_key`.
  @fallback_key :crypto.strong_rand_bytes(32)

  @doc """
  Returns a child specification for the credential backend process.

  Enables the module to be started in the application's supervision tree.
  """
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end

  @doc """
  Starts the credential backend process and creates the ETS table.

  Call this from the supervision tree. The process owns the ETS table and
  keeps it alive for the lifetime of the application.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    Agent.start_link(
      fn ->
        ensure_table!()
        :ok
      end,
      name: name
    )
  end

  # ── ETS table management ──────────────────────────────────────────────

  defp ensure_table! do
    case :ets.whereis(@table_name) do
      :undefined ->
        :ets.new(@table_name, [:set, :public, :named_table])

      _tid ->
        :ok
    end
  end

  # ── Encryption key ─────────────────────────────────────────────────────

  defp encryption_key do
    case EzagentPluginGithub.Config.token_encryption_key() do
      nil ->
        @fallback_key

      encoded when is_binary(encoded) ->
        # Decode from base64 — the env var stores a base64-encoded 32-byte key
        case Base.decode64(encoded) do
          {:ok, key} when byte_size(key) == 32 -> key
          _ -> @fallback_key
        end
    end
  end

  # ── Callbacks ──────────────────────────────────────────────────────────

  @impl true
  def store(command) do
    {:write_only_handoff, token} = command.credential_material

    ref =
      "github-credential-#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"

    encrypted = GitHubTokenStore.encrypt(token, encryption_key())
    :ets.insert(@table_name, {ref, {encrypted, 1}})
    {:ok, %{credential_ref: ref, credential_version: 1}}
  end

  @impl true
  def replace(command) do
    ref = command.credential_ref

    case :ets.lookup(@table_name, ref) do
      [{^ref, {_encrypted, version}}]
      when is_integer(version) and version == command.expected_credential_version ->
        {:write_only_handoff, new_token} = command.credential_material
        new_encrypted = GitHubTokenStore.encrypt(new_token, encryption_key())
        new_version = version + 1
        :ets.insert(@table_name, {ref, {new_encrypted, new_version}})
        {:ok, %{credential_ref: ref, credential_version: new_version}}

      [{^ref, {_encrypted, _version}}] ->
        {:error, :stale_version}

      [] ->
        {:error, :credential_conflict}
    end
  end

  @impl true
  def status(command) do
    case :ets.lookup(@table_name, command.credential_ref) do
      [{_ref, {_encrypted, version}}] ->
        {:ok, %{credential_ref: command.credential_ref, credential_version: version}}

      [] ->
        {:error, :credential_conflict}
    end
  end

  @impl true
  def lease_for_operation(command) do
    ref = command.credential_ref

    case :ets.lookup(@table_name, ref) do
      [{^ref, {{nonce, ciphertext_with_tag}, _version}}] ->
        case GitHubTokenStore.decrypt({nonce, ciphertext_with_tag}, encryption_key()) do
          {:ok, token} ->
            stash_token(token)
            {:ok, %{credential: token, credential_ref: ref, expires_at: nil}}

          {:error, reason} ->
            {:error, reason}
        end

      [] ->
        {:error, :credential_conflict}
    end
  end

  @impl true
  def consume_lease(_command), do: :ok

  @impl true
  def begin_refresh_exchange(_command), do: {:error, :backend_unavailable}

  @impl true
  def consume_refresh_exchange(_command), do: {:error, :backend_unavailable}

  @impl true
  def revoke(command) do
    :ets.delete(@table_name, command.credential_ref)
    :ok
  end

  # ── Token stash (process-dictionary, for adapter use) ─────────────────

  @doc """
  Stores the decrypted token in the process dictionary for the current
  process's adapter operations. The token is NOT logged or inspected.
  """
  @spec stash_token(String.t()) :: :ok
  def stash_token(token) when is_binary(token) do
    Process.put(:github_adapter_token, token)
    :ok
  end

  @doc """
  Reads the currently stashed token from the process dictionary.

  Returns `nil` if no token has been stashed (no active lease in this process).
  """
  @spec current_token() :: String.t() | nil
  def current_token do
    Process.get(:github_adapter_token)
  end
end
