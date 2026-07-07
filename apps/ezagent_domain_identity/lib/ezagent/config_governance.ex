defmodule Ezagent.ConfigGovernance do
  @moduledoc """
  Subject-agnostic helpers for ConfigGovernance change-request workflows.

  This module owns only shared assertions around the CR row. Subject policy and
  observable error terms stay with each caller.
  """

  alias Ezagent.ConfigGovernance.Store

  @type status_error :: {:error, {:status_mismatch, %{want: String.t(), got: String.t()}}}
  @type workspace_error :: {:error, {:workspace_mismatch, String.t(), String.t()}}

  @doc "Fetch a CR and normalize the store's `:none` result."
  @spec fetch_cr(String.t()) :: {:ok, struct()} | {:error, :cr_not_found}
  def fetch_cr(cr_id) when is_binary(cr_id) do
    case Store.fetch(cr_id) do
      {:ok, cr} -> {:ok, cr}
      :none -> {:error, :cr_not_found}
    end
  end

  @doc "Assert that the CR currently has `expected` status."
  @spec assert_status(struct(), String.t()) :: :ok | status_error()
  def assert_status(%{status: expected}, expected), do: :ok

  def assert_status(%{status: got}, expected) when is_binary(expected) do
    {:error, {:status_mismatch, %{want: expected, got: got}}}
  end

  @doc "Assert that the CR workspace matches the caller context workspace."
  @spec assert_workspace(struct(), map()) :: :ok | workspace_error()
  def assert_workspace(%{workspace_uri: cr_workspace}, %{workspace_uri: caller_workspace}) do
    caller = uri_string(caller_workspace)

    if cr_workspace == caller do
      :ok
    else
      {:error, {:workspace_mismatch, cr_workspace, caller}}
    end
  end

  defp uri_string(%URI{} = uri), do: URI.to_string(uri)
  defp uri_string(uri) when is_binary(uri), do: uri
end
