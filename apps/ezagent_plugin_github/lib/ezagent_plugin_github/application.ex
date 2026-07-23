defmodule EzagentPluginGithub.Application do
  @moduledoc """
  GitHub App plugin OTP application — the `Ezagent.Plugin` contract module.

  Implements the GitHub App provider plugin for Git operations. Provides
  user-to-server OAuth for identity, App-JWT-minted installation access tokens
  for repository operations (via the DomainGit.Adapter contract), webhook
  signature verification, and encrypted token storage via the CredentialBackend
  contract.

  ## Plugin authoring contract

  Per `docs/superpowers/specs/2026-05-22-plugin-authoring-contract.md`,
  this module `use`s both `Application` (OTP plumbing) and
  `Ezagent.Plugin` (the declarative contract). `start/2` collapses to
  `Ezagent.Plugin.boot(__MODULE__)`; the plugin author never calls a
  `*Registry` API directly (contract SPEC §3.2 — the `:ezagent_plugin_check`
  grep gate enforces this). Registration is DECLARATIVE:

    * the provider-connection **driver + backend-pair** are reconciled into
      `DriverRegistry` / `BackendPairRegistry` by a supervised
      `Ezagent.ProviderConnection.DeclarationOwner` listed in `children/0`
      (it also restores the rows across registry restarts);
    * the git **adapter** is registered into `Ezagent.DomainGit.AdapterRegistry`
      by a supervised `Ezagent.DomainGit.AdapterDeclarationOwner`, also listed in
      `children/0` (it runs in this plugin's lifecycle, where `GitHubAdapter` is
      loaded — the registry validates `:code.is_loaded/1`).

  Both registration owners live in domain code, so the `.register` calls never
  appear in this plugin's source.
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
      name: "GitHub App",
      description: "GitHub App provider plugin for Git operations",
      version: "0.1.0"
    }
  end

  @impl Ezagent.Plugin
  def children,
    do: [
      EzagentPluginGithub.GitHubCredentialBackend,
      EzagentPluginGithub.GitHubInstallation,
      # All registration is DECLARATIVE, via supervised owners started in THIS
      # plugin's lifecycle — the plugin never calls a `*Registry` API from its
      # own source (contract SPEC §3.2); each `.register` happens inside the
      # owner, which is domain code:
      #   * provider-connection driver + backend-pair → `DeclarationOwner` (also
      #     reconciles the rows across provider-registry restarts);
      #   * the DomainGit adapter → `AdapterDeclarationOwner`. It MUST run in the
      #     plugin lifecycle (not domain_git's config-driven BootRegistration):
      #     `AdapterRegistry` validates `:code.is_loaded/1` and domain_git boots
      #     BEFORE this plugin, so only here is `GitHubAdapter` guaranteed loaded.
      {Ezagent.ProviderConnection.DeclarationOwner,
       owner: :github_plugin,
       drivers: [driver_declaration()],
       backend_pairs: [backend_pair()]},
      {Ezagent.DomainGit.AdapterDeclarationOwner,
       owner: :github_plugin,
       adapters: [{"github", EzagentPluginGithub.GitHubAdapter}]}
    ]

  # NOTE: no `after_boot/0` override. Registration is declarative (see the
  # moduledoc + `children/0`); `use Ezagent.Plugin` supplies the default
  # `after_boot/0 -> :ok`. A plugin must not call a registry's register/declare
  # API from its own source — the `:ezagent_plugin_check` grep gate rejects it.

  @doc """
  Returns the `BackendPair` declaration for the GitHub App plugin.

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
  Returns the `Driver` declaration for the GitHub App plugin.

  Declares the `github` / `oauth_user` driver (user-to-server identity flow) that
  maps to `EzagentPluginGithub.GitHubDriver` and the `pair-github-v1` backend pair.
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
