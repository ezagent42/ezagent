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
  def children, do: [EzagentPluginForgejo.ForgejoCredentialBackend]
end
