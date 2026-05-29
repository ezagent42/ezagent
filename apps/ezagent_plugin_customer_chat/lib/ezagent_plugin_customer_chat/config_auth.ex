defmodule EzagentPluginCustomerChat.ConfigAuth do
  @moduledoc """
  Authorization for editing a tenant's customer-chat configuration (the soul).

  Option E (design §5.5): "whoever administers tenant X may configure tenant X's
  plugins." Gated on the workspace-admin capability via the standard matcher, so
  the bootstrap admin passes through its stored all-`:any` cap — NOT via an
  `is_system_member?` membership bypass. Operators/responders (who hold only
  `Mode.set`) are correctly excluded.
  """

  @doc "True if `caller` may configure the customer-chat plugin for `tenant`."
  @spec config_admin?(URI.t() | nil, String.t() | nil) :: boolean()
  def config_admin?(%URI{} = caller, tenant) when is_binary(tenant) do
    caller
    |> Ezagent.Identity.list_caps_for()
    |> caps_admit?(tenant)
  end

  def config_admin?(_caller, _tenant), do: false

  @doc false
  # Pure cap-set predicate, split out (and exposed @doc false) so the cap logic
  # is unit-testable WITHOUT the Kind registry. Unlike OperatorAuth — whose
  # analogous predicate is private and therefore untested — for a security gate
  # the narrow visibility is worth getting the cap logic under test.
  @spec caps_admit?(MapSet.t(Ezagent.Capability.t()) | [Ezagent.Capability.t()], String.t()) ::
          boolean()
  def caps_admit?(caps, tenant) when is_binary(tenant) do
    ws = URI.parse("workspace://#{tenant}")

    needed = %{
      kind: :workspace,
      behavior: Ezagent.Behavior.Workspace,
      action: :any,
      instance: ws,
      workspace_uri: ws
    }

    Enum.any?(caps, &Ezagent.Capability.matches?(&1, needed))
  end
end
