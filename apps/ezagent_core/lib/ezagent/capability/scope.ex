defmodule Ezagent.Capability.Scope do
  @moduledoc false

  alias Ezagent.Capability

  @spec cross_workspace?(Capability.t()) :: boolean()
  def cross_workspace?(%Capability{workspace_uri: :any}), do: true
  def cross_workspace?(%Capability{}), do: false

  @spec cross_workspace?(Capability.t(), URI.t() | :system | nil) :: boolean()
  def cross_workspace?(%Capability{workspace_uri: :any}, _caller_uri), do: true

  def cross_workspace?(%Capability{}, %URI{} = caller_uri) do
    home_is_system?(caller_uri) or member_of_system?(caller_uri)
  end

  def cross_workspace?(%Capability{}, _), do: false

  @spec home_is_system?(URI.t()) :: boolean()
  def home_is_system?(%URI{} = caller_uri) do
    case workspace_of_caller_safe(caller_uri) do
      %URI{} = workspace -> Ezagent.URI.name?(workspace, :system)
      _ -> false
    end
  end

  def home_is_system?(_), do: false

  @spec member_of_system?(URI.t()) :: boolean()
  def member_of_system?(%URI{} = caller_uri) do
    if Code.ensure_loaded?(Ezagent.Workspace.Store) and
         function_exported?(Ezagent.Workspace.Store, :get_by_name, 1) do
      case apply(Ezagent.Workspace.Store, :get_by_name, ["system"]) do
        %{members: members} when is_list(members) ->
          caller_str = URI.to_string(caller_uri)
          Enum.any?(members, fn m -> URI.to_string(m) == caller_str end)

        _ ->
          false
      end
    else
      false
    end
  end

  def member_of_system?(_), do: false

  @spec workspace_of(URI.t()) :: URI.t() | :any
  def workspace_of(%URI{} = uri), do: Ezagent.URI.workspace_of(uri)

  defp workspace_of_caller_safe(%URI{} = uri) do
    try do
      workspace_of(uri)
    rescue
      _ -> :any
    end
  end
end
