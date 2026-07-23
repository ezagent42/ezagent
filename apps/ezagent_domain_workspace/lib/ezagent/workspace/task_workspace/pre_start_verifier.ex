defmodule Ezagent.Workspace.TaskWorkspace.PreStartVerifier do
  @moduledoc false

  alias Ezagent.Workspace.TaskWorkspace.GitRunner

  @spec verify(map()) :: :ok | {:error, term()}
  if Mix.env() == :test do
    @doc "Verifies that a prepared task workspace still matches its governed Git proof."
    def verify(proof) do
      :ezagent_domain_workspace
      |> Application.get_env(:task_workspace_git_runner, GitRunner)
      |> apply(:verify, [proof])
    end
  else
    @doc "Verifies that a prepared task workspace still matches its governed Git proof."
    def verify(proof), do: GitRunner.verify(proof)
  end
end
