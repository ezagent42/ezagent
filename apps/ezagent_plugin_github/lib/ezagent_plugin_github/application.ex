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
  def after_boot, do: :ok
end
