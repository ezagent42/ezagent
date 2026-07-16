defmodule Ezagent.ActionSet.GitTaskAccess do
  @moduledoc """
  Minimal Lifecycle host for the authoritative Git task-access policy.

  Task 5 defines only creation of the live policy slice. Git operations and
  their effects are added in Task 8; this module performs no adapter lookup or
  callback and declares no dispatchable action yet.
  """

  use Ezagent.Lifecycle

  alias Ezagent.Entity.GitTaskAccess

  @impl Ezagent.Lifecycle
  def create(%{uri: uri, policy: policy}) do
    with {:ok, validated} <- GitTaskAccess.revalidate(policy),
         true <- uri == GitTaskAccess.uri_from_args(validated) do
      {:ok, %{policy: validated}}
    else
      false -> raise ArgumentError, "GitTaskAccess spawn URI does not match policy"
      {:error, reason} -> raise ArgumentError, "invalid GitTaskAccess policy: #{inspect(reason)}"
    end
  end
end
