defmodule Ezagent.ActionSet.GitWorkflow do
  @moduledoc """
  Minimal GitWorkflow ActionSet — E2 surface.

  Exposes only binding management (register/disable) and claim/read-run.
  No materialize/spawn/provision/create_pr/wait_ci/merge/project actions.
  """

  use Ezagent.ActionSet

  action :register_binding,
    args: %{binding: :map},
    returns: %{binding: :map},
    caps: [%{behavior: Ezagent.ActionSet.GitWorkflow, action: :register_binding}]

  action :disable_binding,
    args: %{binding_id: :string},
    returns: %{binding: :map},
    caps: [%{behavior: Ezagent.ActionSet.GitWorkflow, action: :disable_binding}]

  action :claim_task,
    args: %{task: :map},
    returns: %{run: :map},
    caps: [%{behavior: Ezagent.ActionSet.GitWorkflow, action: :claim_task}]

  action :read_run,
    args: %{run_id: :string},
    returns: %{run: :map},
    caps: [%{behavior: Ezagent.ActionSet.GitWorkflow, action: :read_run}]

  @doc false
  def actions, do: __action_names__()

  @doc false
  @spec handle_register_binding(map(), map()) :: {:ok, map(), [tuple()]}
  def handle_register_binding(%{binding: binding_attrs}, _ctx) do
    case EzagentPluginGitWorkflow.TaskBinding.new(binding_attrs) do
      {:ok, binding} ->
        case EzagentPluginGitWorkflow.Store.register_binding(binding) do
          {:ok, registered} ->
            {:ok, %{binding: Map.from_struct(registered)}, []}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def handle_disable_binding(%{binding_id: binding_id}, _ctx) do
    case EzagentPluginGitWorkflow.Store.disable_binding(binding_id) do
      {:ok, binding} -> {:ok, %{binding: Map.from_struct(binding)}, []}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def handle_claim_task(%{task: task_attrs}, ctx) do
    principal = Map.get(ctx, :authenticated_principal)

    if is_nil(principal) do
      {:error, :authenticated_principal_required}
    else
      run_attrs =
        task_attrs
        |> Map.put(:authenticated_principal_uri, principal)
        |> Map.put_new(:status, "accepted")
        |> Map.put_new(:state_version, 1)

      case EzagentPluginGitWorkflow.WorkflowRun.new(run_attrs) do
        {:ok, run} ->
          case EzagentPluginGitWorkflow.Store.claim(run) do
            {:ok, claimed} ->
              {:ok, %{run: Map.from_struct(claimed)}, []}

            {:error, reason} ->
              {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc false
  def handle_read_run(%{run_id: run_id}, _ctx) do
    case EzagentPluginGitWorkflow.Store.read_run(run_id) do
      {:ok, run} -> {:ok, %{run: Map.from_struct(run)}, []}
      {:error, reason} -> {:error, reason}
    end
  end
end
