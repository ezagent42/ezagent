defmodule Ezagent.Workspace.TaskWorkspace.AgentStart.Ref do
  @moduledoc false

  @opaque t :: %__MODULE__{
            provision_id: String.t(),
            task_access_uri: URI.t(),
            task_uri: URI.t(),
            generation: pos_integer()
          }
  @enforce_keys [:provision_id, :task_access_uri, :task_uri, :generation]
  defstruct [:provision_id, :task_access_uri, :task_uri, :generation]
end
