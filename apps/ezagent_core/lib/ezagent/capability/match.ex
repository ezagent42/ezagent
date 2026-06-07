defmodule Ezagent.Capability.Match do
  @moduledoc false

  alias Ezagent.Capability
  alias Ezagent.Capability.Scope

  @spec matches?(Capability.t(), %{
          required(:kind) => atom(),
          required(:behavior) => module(),
          required(:action) => atom(),
          required(:instance) => URI.t(),
          required(:workspace_uri) => URI.t() | :any
        }) :: boolean()
  def matches?(%Capability{} = cap, %{
        kind: k,
        behavior: b,
        action: a,
        instance: i,
        workspace_uri: w
      }) do
    field_match?(cap.kind, k) and
      field_match?(cap.behavior, b) and
      field_match?(action_of(cap), a) and
      instance_match?(cap.instance, i) and
      workspace_match?(cap.workspace_uri, w)
  end

  def matches?(
        %Capability{} = cap,
        %{
          kind: _,
          behavior: _,
          instance: _,
          workspace_uri: _
        } = needed
      )
      when not is_map_key(needed, :action) do
    matches?(cap, Map.put(needed, :action, :any))
  end

  @spec action_of(Capability.t() | map()) :: atom()
  def action_of(cap), do: Map.get(cap, :action, :any)

  @spec identity_key(Capability.t()) ::
          {atom() | :any, module() | :any, atom() | :any,
           URI.t() | :any | Capability.scope_tuple(), URI.t() | :any}
  def identity_key(
        %Capability{
          kind: k,
          behavior: b,
          instance: i,
          workspace_uri: w
        } = cap
      ),
      do: {k, b, action_of(cap), normalize_uri_for_key(i), normalize_uri_for_key(w)}

  @spec cap_for_action(module(), atom(), URI.t()) :: %{
          kind: atom(),
          behavior: module(),
          action: atom(),
          instance: URI.t(),
          workspace_uri: URI.t() | :any
        }
  def cap_for_action(kind_module, action, %URI{} = target_uri)
      when is_atom(kind_module) and is_atom(action) do
    behavior =
      case Ezagent.BehaviorRegistry.lookup(kind_module, action) do
        {:ok, behavior_module} -> behavior_module
        :error -> :unknown
      end

    %{
      kind: kind_module.type_name(),
      behavior: behavior,
      action: action,
      instance: Ezagent.URI.instance(target_uri),
      workspace_uri: Scope.workspace_of(target_uri)
    }
  end

  defp field_match?(:any, _), do: true
  defp field_match?(same, same), do: true
  defp field_match?(_, _), do: false

  defp instance_match?(:any, _), do: true

  defp instance_match?({:within_session, %URI{} = session_uri}, %URI{} = needed_instance) do
    needed_str = URI.to_string(needed_instance)
    session_str = URI.to_string(session_uri)

    needed_str == session_str or String.starts_with?(needed_str, session_str <> "/")
  end

  defp instance_match?({:within_workspace, %URI{} = workspace_uri}, %URI{} = needed_instance) do
    case Scope.workspace_of(needed_instance) do
      %URI{} = needed_ws -> URI.to_string(needed_ws) == URI.to_string(workspace_uri)
      :any -> false
    end
  end

  defp instance_match?({:spawned_by, %URI{} = principal_uri}, %URI{} = needed_instance) do
    Ezagent.AgentLineage.spawned_in_lineage?(needed_instance, principal_uri)
  end

  defp instance_match?(%URI{} = held, %URI{} = needed),
    do: URI.to_string(held) == URI.to_string(needed)

  defp instance_match?(same, same), do: true
  defp instance_match?(_, _), do: false

  defp workspace_match?(:any, _), do: true
  defp workspace_match?(_, :any), do: true

  defp workspace_match?(%URI{} = held, %URI{} = needed),
    do: URI.to_string(held) == URI.to_string(needed)

  defp workspace_match?(_, _), do: false

  defp normalize_uri_for_key(%URI{} = u), do: Ezagent.URI.stable_key(u)
  defp normalize_uri_for_key(other), do: other
end
