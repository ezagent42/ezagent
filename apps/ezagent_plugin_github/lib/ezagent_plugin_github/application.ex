defmodule EzagentPluginGithub.Application do
  @moduledoc """
  GitHub OAuth plugin OTP application — the `Ezagent.Plugin` contract module.

  Implements the GitHub OAuth App provider plugin for Git operations.
  Provides OAuth-based authorization flows, Git REST API operations via
  the DomainGit.Adapter contract, and encrypted token storage via the
  CredentialBackend contract.

  ## Plugin authoring contract

  Per `docs/superpowers/specs/2026-05-22-plugin-authoring-contract.md`,
  this module `use`s both `Application` (OTP plumbing) and
  `Ezagent.Plugin` (the declarative contract). `start/2` collapses to
  `Ezagent.Plugin.boot(__MODULE__)`; the framework's two-phase
  `boot/1` reads the declaration callbacks below and performs every
  `*Registry` call — the plugin author never touches a registry API.
  """

  use Application
  use Ezagent.Plugin

  # --- OTP Application -------------------------------------------------

  @impl Application
  def start(_type, _args), do: Ezagent.Plugin.boot(__MODULE__)

  # --- Ezagent.Plugin contract ---------------------------------------

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "github",
      name: "GitHub OAuth",
      description: "GitHub OAuth App provider plugin for Git operations",
      version: "0.1.0"
    }
  end

  @impl Ezagent.Plugin
  def children, do: []

  @impl Ezagent.Plugin
  def after_boot do
    pair = backend_pair()

    case Ezagent.ProviderConnection.BackendPairRegistry.register(:github_plugin, pair) do
      :acquired ->
        :ok

      :existing_identical ->
        :ok

      {:error, {:declaration_drift, _expected, _actual}} ->
        raise "BackendPair registry declaration drift detected for pair #{pair.pair_id}"
    end

    driver = driver_declaration()

    case Ezagent.ProviderConnection.DriverRegistry.register(:github_plugin, driver) do
      :acquired ->
        :ok

      :existing_identical ->
        :ok

      {:error, {:declaration_drift, _expected, _actual}} ->
        raise "Driver registry declaration drift detected for #{driver.provider_id}/#{driver.acquisition_method}"
    end

    Code.ensure_loaded(EzagentPluginGithub.GitHubAdapter)

    case Ezagent.DomainGit.AdapterRegistry.register("github", EzagentPluginGithub.GitHubAdapter) do
      :ok ->
        :ok

      {:ok, :already_registered} ->
        :ok

      {:error, drift} ->
        raise "Adapter registry registration drift detected for github: #{inspect(drift)}"
    end

    :ok
  end

  @doc """
  Returns the `BackendPair` declaration for the GitHub OAuth plugin.

  Declares the `pair-github-v1` pair that links the
  `local-authorization-v1` authorization backend with the
  `github-credential-v1` credential backend.
  """
  def backend_pair do
    Ezagent.ProviderConnection.BackendPair.new!(%{
      pair_id: "pair-github-v1",
      authorization_backend: %{id: "local-authorization-v1", fingerprint: "local-v1"},
      credential_backend: %{id: "github-credential-v1", fingerprint: "github-cred-v1"}
    })
  end

  @doc """
  Returns the `Driver` declaration for the GitHub OAuth plugin.

  Declares the `github` / `oauth_user` driver that maps to
  `EzagentPluginGithub.GitHubDriver` and the `pair-github-v1` backend pair.
  """
  def driver_declaration do
    Ezagent.ProviderConnection.Driver.new!(%{
      provider_id: "github",
      acquisition_method: "oauth_user",
      provider_fingerprint: "github-driver-v1",
      implementation: EzagentPluginGithub.GitHubDriver,
      backend_pair_ids: ["pair-github-v1"],
      metadata: %{
        authorization_redirect_schema: %{
          type: :map,
          fields: %{
            "authorization_uri" => %{type: :string},
            "state" => %{type: :string},
            "pkce_digest" => %{type: :string}
          }
        },
        provider_metadata_schema: %{type: :map, fields: %{}}
      }
    })
  end
end
