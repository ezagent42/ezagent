defmodule EzagentPluginCustomerChat.OperatorAuth do
  @moduledoc """
  Operator authorization for the customer-chat console. The operator
  cap IS the takeover cap, workspace-scoped: "if you can take a session
  over (`Mode.set`) in this workspace, you may use the operator console
  for it." A system member (admin) always passes.
  """

  @doc "True if `caller` may operate the customer console for `tenant`."
  @spec operator?(URI.t() | nil, String.t() | nil, boolean()) :: boolean()
  def operator?(nil, _tenant, _sys?), do: false
  def operator?(_caller, nil, _sys?), do: false
  def operator?(_caller, _tenant, true), do: true

  def operator?(%URI{} = caller, tenant, _sys?) when is_binary(tenant) do
    ws = URI.parse("workspace://#{tenant}")

    caller
    |> Ezagent.Identity.list_caps_for()
    |> Enum.any?(&mode_set_cap_for_workspace?(&1, ws))
  end

  @doc "Workspaces (names) the caller may operate, given system-member status."
  @spec servable_tenants(URI.t() | nil, boolean()) :: [String.t()]
  def servable_tenants(caller_uri, sys?) do
    Ezagent.Workspace.Store.list_all()
    |> Enum.map(& &1.name)
    |> Enum.filter(fn t -> operator?(caller_uri, t, sys?) end)
  end

  defp mode_set_cap_for_workspace?(%Ezagent.Capability{} = c, %URI{} = ws) do
    c.kind == :session and c.behavior == Ezagent.Behavior.Mode and c.action == :set and
      (c.workspace_uri == :any or
         (match?(%URI{}, c.workspace_uri) and URI.to_string(c.workspace_uri) == URI.to_string(ws)))
  end

  defp mode_set_cap_for_workspace?(_, _), do: false
end
