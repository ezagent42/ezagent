defmodule Ezagent.Cap.ReissuePolicy.Registry do
  @moduledoc """
  Runtime registry of domain-owned capability re-issuance policies.

  The registry stores modules only. Classification remains pure and happens in
  `Ezagent.Identity.CapReconciler`, which also accepts an explicit module list
  for hermetic tests.
  """

  @table :ezagent_cap_reissue_policies

  @doc false
  def table, do: @table

  @doc false
  @spec register(module(), integer()) :: :ok
  def register(policy, priority \\ 100) when is_atom(policy) and is_integer(priority) do
    with {:module, ^policy} <- Code.ensure_loaded(policy),
         true <- function_exported?(policy, :classify, 1),
         true <- function_exported?(policy, :reissue_action, 2) do
      :ets.insert(@table, {policy, priority})
      :ok
    else
      _ -> raise ArgumentError, "invalid CapReissuePolicy: #{inspect(policy)}"
    end
  end

  @doc false
  @spec unregister(module()) :: :ok
  def unregister(policy) when is_atom(policy) do
    :ets.delete(@table, policy)
    :ok
  end

  @doc false
  @spec policies() :: [module()]
  def policies do
    @table
    |> :ets.tab2list()
    |> Enum.sort_by(fn {policy, priority} -> {priority, policy} end)
    |> Enum.map(fn {policy, _priority} -> policy end)
  rescue
    ArgumentError -> []
  end
end
