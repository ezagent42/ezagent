defmodule Ezagent.Session.InstallCatalog do
  @moduledoc """
  Temporary SessionTemplate install catalog for the socialware unification work.

  P3 intentionally keeps this in code: P4 replaces the built-in catalog with
  ConfigStore-backed socialware definitions. Session creation still consumes
  template data now, so call sites no longer branch on chat vs socialware.
  """

  alias Ezagent.Entity.Session

  @default_installs ["chat"]

  @type install_ref :: String.t() | atom()

  @spec default_installs() :: [String.t()]
  def default_installs, do: @default_installs

  @spec installs_from_template(map()) :: [term()]
  def installs_from_template(content) when is_map(content) do
    case Map.get(content, :installs) || Map.get(content, "installs") do
      installs when is_list(installs) -> installs
      _ -> @default_installs
    end
  end

  def installs_from_template(_), do: @default_installs

  @spec behavior_set_for_template(map()) :: {:ok, [module()]} | {:error, term()}
  def behavior_set_for_template(content) when is_map(content) do
    content
    |> installs_from_template()
    |> behavior_set()
  end

  def behavior_set_for_template(_), do: behavior_set(@default_installs)

  @spec behavior_set([install_ref()]) :: {:ok, [module()]} | {:error, term()}
  def behavior_set(installs) when is_list(installs) do
    with {:ok, behavior_lists} <- behavior_lists(installs) do
      ordered =
        behavior_lists
        |> Enum.reverse()
        |> List.flatten()
        |> Enum.uniq()

      case ordered do
        [] -> {:error, :empty_install_behavior_set}
        _ -> {:ok, ordered}
      end
    end
  end

  def behavior_set(other), do: {:error, {:invalid_installs, other}}

  defp behavior_lists(installs) do
    Enum.reduce_while(installs, {:ok, []}, fn install, {:ok, acc} ->
      case behavior_list(install) do
        {:ok, behaviors} -> {:cont, {:ok, [behaviors | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp behavior_list(install) when is_atom(install), do: behavior_list(Atom.to_string(install))

  defp behavior_list("chat"), do: {:ok, Session.chat_behaviors()}
  defp behavior_list("socialware"), do: {:ok, Session.socialware_behaviors()}

  defp behavior_list(other), do: {:error, {:unknown_install, other}}
end
