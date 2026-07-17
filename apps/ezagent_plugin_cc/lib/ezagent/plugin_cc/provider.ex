defmodule Ezagent.PluginCc.Provider do
  @moduledoc """
  Runtime facade for the cc completion-backend dimension — ORTHOGONAL to
  transport (pty vs headless). All vendor data lives in
  `Ezagent.PluginCc.ProviderCatalog` (closed, server-owned); this module
  resolves the profile selected by template data, injects the deploy-provided
  key from the profile's allowlisted env var, and reports credential status.

  Template data contract: `"provider"` is ABSENT or `"anthropic"` for the
  default cc path (zero extra env, byte-unchanged), or a catalog profile name
  for a custom backend. Unknown names fail CLOSED
  (`{:unknown_backend_profile, _}`) — they never silently degrade to the
  anthropic path (locked decision #9).

  The key is read via `System.get_env(profile.api_key_env)` at launch-build
  time only and lands solely in the child process env — never in template
  data, snapshots, logs, telemetry, or status detail strings (locked #6).
  """

  alias Ezagent.PluginCc.ProviderCatalog

  @provider_key "provider"
  @anthropic "anthropic"

  @doc "The default (Anthropic) provider name."
  @spec anthropic() :: String.t()
  def anthropic, do: @anthropic

  @doc "The provider template-data key."
  @spec provider_key() :: String.t()
  def provider_key, do: @provider_key

  @doc """
  The raw `"provider"` template-data value: `nil` when absent, else the
  string (atom input `"anthropic"`/profile names normalized to strings).
  No validation here — validation is `profile_env/1`'s job (fail closed).
  """
  @spec provider_of(map()) :: String.t() | nil
  def provider_of(tmpl) when is_map(tmpl) do
    case Map.get(tmpl, @provider_key) || Map.get(tmpl, :provider) do
      nil -> nil
      p when is_atom(p) -> Atom.to_string(p)
      p when is_binary(p) -> p
      _ -> nil
    end
  end

  def provider_of(_), do: nil

  @doc """
  The launch-time env map to MERGE into the claude launch env for `tmpl`.

    * no provider / explicit anthropic → `{:ok, %{}}` (default cc path
      byte-unchanged — no vendor vars ever leak in);
    * catalog profile → the profile's static block + `ANTHROPIC_BASE_URL` +
      `ANTHROPIC_AUTH_TOKEN` (read from the profile's allowlisted env var);
      key unset/empty → `{:error, {:backend_api_key_missing, name}}`;
    * unknown profile → `{:error, {:unknown_backend_profile, name}}`.
  """
  @spec provider_env(map()) ::
          {:ok, %{optional(String.t()) => String.t()}}
          | {:error, {:unknown_backend_profile, String.t()}}
          | {:error, {:backend_api_key_missing, String.t()}}
  def provider_env(tmpl) when is_map(tmpl) do
    case provider_of(tmpl) do
      nil -> {:ok, %{}}
      @anthropic -> {:ok, %{}}
      name -> profile_env(name)
    end
  end

  @doc "Assemble a named profile's full env block (see `provider_env/1`)."
  @spec profile_env(String.t()) ::
          {:ok, %{optional(String.t()) => String.t()}}
          | {:error, {:unknown_backend_profile, String.t()}}
          | {:error, {:backend_api_key_missing, String.t()}}
  def profile_env(name) when is_binary(name) do
    with {:ok, profile} <- ProviderCatalog.fetch(name),
         {:ok, token} <- api_key(profile) do
      {:ok,
       Map.merge(profile.static_env, %{
         "ANTHROPIC_BASE_URL" => profile.base_url,
         "ANTHROPIC_AUTH_TOKEN" => token
       })}
    else
      :error -> {:error, {:unknown_backend_profile, name}}
      {:error, :missing_key} -> {:error, {:backend_api_key_missing, name}}
    end
  end

  @doc """
  PTY-only bridge-topic env for a custom-backend agent — the esr-bridge
  sidecar joins `agent_bridge:<flavor>:<uri>`; empty for the default
  anthropic path (the sidecar default is already correct) and for headless
  (in-process, no WS topic). Vendor-neutral: keys off the template's
  `"flavor"`, gated on a non-anthropic provider.
  """
  @spec bridge_topic_env(map(), URI.t()) :: %{optional(String.t()) => String.t()}
  def bridge_topic_env(tmpl, %URI{} = agent_uri) when is_map(tmpl) do
    with p when is_binary(p) <- provider_of(tmpl),
         true <- p != @anthropic,
         flavor when is_binary(flavor) and flavor != "" <-
           Map.get(tmpl, "flavor") || Map.get(tmpl, :flavor) do
      %{"EZAGENT_BRIDGE_TOPIC" => "agent_bridge:#{flavor}:#{Ezagent.URI.stable_key(agent_uri)}"}
    else
      _ -> %{}
    end
  end

  @doc """
  Fail-fast launchability gate: `:ok` iff the profile's env var is set,
  else `{:error, {:backend_api_key_missing, name, uri}}`. Checked at the top
  of a custom-backend `instantiate/3` BEFORE any Kind spawn / transport-join
  wait.
  """
  @spec ensure_api_key(String.t(), URI.t()) ::
          :ok
          | {:error, {:backend_api_key_missing, String.t(), URI.t()}}
          | {:error, {:unknown_backend_profile, String.t(), URI.t()}}
  def ensure_api_key(name, %URI{} = agent_uri) when is_binary(name) do
    case ProviderCatalog.fetch(name) do
      {:ok, profile} ->
        if api_key_present?(profile),
          do: :ok,
          else: {:error, {:backend_api_key_missing, name, agent_uri}}

      :error ->
        {:error, {:unknown_backend_profile, name, agent_uri}}
    end
  end

  @doc """
  Per-profile credential status (the #160 normalized enum), env-backed:
  key set → `:authenticated`; unset → `:missing` with an operator-facing
  detail naming the ENV VAR (never the value); nil/unknown profile →
  `:unknown` (never an alarm). Read-only, no network, no activation.
  """
  @spec credential_status(String.t() | nil) ::
          %{status: atom(), detail: String.t() | nil, expires_at: nil}
  def credential_status(name) when is_binary(name) do
    case ProviderCatalog.fetch(name) do
      {:ok, profile} ->
        if api_key_present?(profile) do
          %{status: :authenticated, detail: nil, expires_at: nil}
        else
          %{
            status: :missing,
            detail:
              "#{profile.api_key_env} not set — the \"#{name}\" backend has no " <>
                "credential; set #{profile.api_key_env} in the deploy env.",
            expires_at: nil
          }
        end

      :error ->
        %{status: :unknown, detail: nil, expires_at: nil}
    end
  end

  def credential_status(_), do: %{status: :unknown, detail: nil, expires_at: nil}

  # --- internals -----------------------------------------------------------

  defp api_key(%{api_key_env: env}) do
    case System.get_env(env) do
      k when is_binary(k) and k != "" -> {:ok, k}
      _ -> {:error, :missing_key}
    end
  end

  defp api_key_present?(profile), do: match?({:ok, _}, api_key(profile))
end
