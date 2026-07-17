defmodule Ezagent.Workspace.TaskWorkspace.PreStartVerifier do
  @moduledoc false

  alias Ezagent.Workspace.TaskWorkspace.GitRunner

  @spec verify(map()) :: :ok | {:error, term()}
  if Mix.env() == :test do
    def verify(proof) do
      :ezagent_domain_workspace
      |> Application.get_env(:task_workspace_git_runner, GitRunner)
      |> apply(:verify, [proof])
    end
  else
    def verify(proof), do: GitRunner.verify(proof)
  end
end
