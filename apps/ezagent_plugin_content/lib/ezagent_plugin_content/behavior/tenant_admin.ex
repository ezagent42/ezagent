defmodule EzagentPluginContent.Behavior.TenantAdmin do
  @moduledoc """
  System-scoped tenant lifecycle Behavior. Registered via `CapabilityRegistry`
  only (stateless — no slice, no `behaviors/0` entry on System Kind).

  Action: `:create_tenant` — bootstrap a new tenant workspace + sandbox dir.

  ## Design — stateless thin wrapper

  - NO persistent slice
  - Handler delegates to `TenantProvisioner.create_tenant/3`
  - Registered via `CapabilityRegistry.register/3`
  - NOT in System Kind's `behaviors/0`
  """

  use Ezagent.Lifecycle

  alias EzagentPluginContent.Tenant.TenantProvisioner

  action(:create_tenant,
    args: %{tid: :string, brand_name: :string, industry: :string},
    returns: %{tenant_id: :string, sandbox: :string, cr_id: :string},
    caps: [:create_tenant],
    modes: [:call],
    description: "create a new tenant with workspace, sandbox directory, and initial CR"
  )

  def required_caps do
    %{
      create_tenant: Ezagent.Capability.cap(:system, __MODULE__, :create_tenant)
    }
  end

  def workspace_scoped?, do: false
  def data_owner(_), do: :no_owner

  def handle_create_tenant(args, _ctx) do
    %{tid: tid, brand_name: brand_name, industry: industry} = args

    case TenantProvisioner.create_tenant(tid, brand_name, industry: industry) do
      {:ok, %{tenant_id: tid, sandbox: sandbox, cr_id: cr_id}} ->
        {:ok, %{tenant_id: tid, sandbox: sandbox, cr_id: cr_id}}

      {:error, _} = err ->
        err
    end
  end
end
