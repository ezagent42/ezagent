defmodule EzagentPluginHello.OfficialSiteSeed do
  @moduledoc """
  Governed, absence-gated provisioner for the official Hello session.

  The founder is an existing non-admin user selected by this deployment's
  seed configuration. This module never creates a user, falls back to a
  hard-coded principal, or materializes credentials from an environment key.
  """

  alias Ezagent.Entity.{Profile, User}
  alias Ezagent.Socialware.ExternalFeed
  alias EzagentPluginHello.FusionSeed

  @name "ezagent-official"

  @type outcome ::
          {:ok, {:provisioned, URI.t(), String.t()}}
          | {:ok, {:already_provisioned, URI.t()}}
          | {:error, term()}

  @spec site_uri() :: URI.t()
  def site_uri, do: Ezagent.URI.session(EzagentPluginHello.home_workspace(), :hello, @name)

  @spec boot_enabled?() :: boolean()
  def boot_enabled?, do: Application.get_env(:ezagent_plugin_hello, :site_seed_boot, false)

  @spec ensure() :: outcome()
  def ensure do
    with {:ok, owner} <- resolve_founder() do
      case current_page() do
        {:present, uri} -> {:ok, {:already_provisioned, uri}}
        :absent -> provision(owner)
      end
    end
  end

  defp resolve_founder do
    home = EzagentPluginHello.home_workspace()

    with email when is_binary(email) and email != "" <- founder_email(),
         %Profile{entity_uri: entity_uri} <- Profile.by_email(email),
         {:ok, %URI{} = founder} <- URI.new(entity_uri),
         true <- Ezagent.Capability.workspace_of(founder) == Ezagent.URI.workspace(home) do
      {:ok, founder}
    else
      nil -> {:error, :official_site_founder_not_found}
      false -> {:error, :official_site_founder_wrong_workspace}
      _ -> {:error, :official_site_founder_unconfigured}
    end
  end

  # Deployment provisioning loads this value from that environment's seed.env.
  # It is intentionally a reference to an already-created user, never a secret.
  defp founder_email do
    Application.get_env(:ezagent_plugin_hello, :official_site_founder_email)
  end

  defp current_page do
    uri = site_uri()

    case ExternalFeed.snapshot(uri, User.admin_uri()) do
      {:ok, %{page: page}} when not is_nil(page) -> {:present, uri}
      _ -> :absent
    end
  end

  defp provision(owner) do
    case FusionSeed.run(workspace: EzagentPluginHello.home_workspace(), name: @name, owner: owner) do
      {:ok, %{session_uri: uri, turn_id: turn_id}} -> {:ok, {:provisioned, uri, turn_id}}
      {:error, _reason} = error -> error
      other -> {:error, {:unexpected_seed_result, other}}
    end
  end
end
