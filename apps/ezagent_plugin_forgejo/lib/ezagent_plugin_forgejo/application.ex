defmodule EzagentPluginForgejo.Application do
  @moduledoc """
  Forgejo provider plugin OTP application — the `Ezagent.Plugin` contract module.

  Implements the Forgejo (and Gitea — same API base, see design §1) provider
  plugin for Git operations, per
  `docs/superpowers/specs/2026-07-29-forgejo-provider-v1-design.md`.

  ## Slice F1 scope

  This slice delivers the plugin skeleton only: instance URL derivation, the
  HTTP client, and credential storage. It deliberately registers **no**
  `Ezagent.DomainGit.AdapterRegistry` entry — `AdapterRegistry.register/2`
  validates that the module implements all five `DomainGit.Adapter` callbacks,
  and `ForgejoAdapter` does not exist until F2/F3. Registering a stub that
  answered every callback with an error would be a fake, not a skeleton; the
  adapter declaration is added in F2 alongside the read path it can honestly
  serve.

  ## Plugin authoring contract

  Per `docs/superpowers/specs/2026-05-22-plugin-authoring-contract.md`, this
  module `use`s both `Application` (OTP plumbing) and `Ezagent.Plugin` (the
  declarative contract). `start/2` collapses to
  `Ezagent.Plugin.boot(__MODULE__)`; the plugin author never calls a
  `*Registry` API directly (contract SPEC §3.2 — the `:ezagent_plugin_check`
  grep gate enforces this).
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
      slug: "forgejo",
      name: "Forgejo",
      description: "Forgejo/Gitea provider plugin for Git operations",
      version: "0.1.0"
    }
  end

  @impl Ezagent.Plugin
  def children,
    do: [
      EzagentPluginForgejo.ForgejoCredentialBackend,
      # Registration is DECLARATIVE: the driver and backend pair are reconciled
      # into `DriverRegistry` / `BackendPairRegistry` by a supervised owner that
      # lives in domain code, so no `.register` call appears in this plugin's
      # source (contract SPEC §3.2 — the `:ezagent_plugin_check` grep gate
      # rejects it).
      #
      # No `Ezagent.DomainGit.AdapterDeclarationOwner` yet: `AdapterRegistry`
      # validates all five `DomainGit.Adapter` callbacks and `ForgejoAdapter`
      # arrives in slice F2, so declaring one here could only point at a stub.
      {Ezagent.ProviderConnection.DeclarationOwner,
       owner: :forgejo_plugin, drivers: [driver_declaration()], backend_pairs: [backend_pair()]}
    ]

  @doc """
  Returns the `BackendPair` declaration for the Forgejo plugin.

  Pairs the shared local authorization backend with this plugin's credential
  backend, which is what makes the domain route Forgejo credential custody —
  including renewal — through `EzagentPluginForgejo.ForgejoCredentialBackend`.
  """
  def backend_pair do
    Ezagent.ProviderConnection.BackendPair.new!(%{
      pair_id: "pair-forgejo-v1",
      authorization_backend: %{id: "local-authorization-v1", fingerprint: "local-v1"},
      credential_backend: %{id: "forgejo-credential-v1", fingerprint: "forgejo-cred-v1"}
    })
  end

  @doc """
  Returns the `Driver` declaration for the Forgejo plugin.

  **One declaration serves every Forgejo instance.** A declaration is
  process-wide and holds only stable, non-secret data, which is exactly why no
  `client_id` appears here: those are per-instance and per-tenant, and live in
  `EzagentPluginForgejo.OAuthApp` keyed by `{workspace_uri, governed_host}`.
  The connection's `governed_host` selects the right one at authorization time.
  """
  def driver_declaration do
    Ezagent.ProviderConnection.Driver.new!(%{
      provider_id: "forgejo",
      acquisition_method: "oauth_user",
      provider_fingerprint: "forgejo-driver-v1",
      implementation: EzagentPluginForgejo.ForgejoDriver,
      backend_pair_ids: ["pair-forgejo-v1"],
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
