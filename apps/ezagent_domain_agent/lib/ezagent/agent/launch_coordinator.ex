defmodule Ezagent.Agent.LaunchCoordinator do
  @moduledoc """
  Commits the ownership facts carried by a trusted launch handle.

  Durable inventory and lineage are written in one transaction before the
  Agent Kind may become visible. ETS publication and authority acknowledgement
  happen only after commit and are consistency operations, never ownership.
  """

  alias Ezagent.Agent.{CreationInventory, LaunchAuthority}
  alias EzagentCore.Repo

  @post_commit_publisher Application.compile_env(
                           :ezagent_domain_agent,
                           :launch_post_commit_publisher,
                           Ezagent.Agent.LaunchPostCommitPublisher.Production
                         )

  @type receipt :: %{
          attempt_id: String.t(),
          agent_uri: URI.t(),
          root_uri: URI.t(),
          workspace_uri: URI.t()
        }

  @doc "Commits and publishes the exact ownership facts for a winning Agent child."
  @spec consume_before_start(URI.t(), reference()) :: {:ok, receipt()} | {:error, term()}
  def consume_before_start(%URI{} = requested_uri, handle) do
    with {:ok, facts} <- LaunchAuthority.resolve(handle, requested_uri),
         :ok <- validate(facts, requested_uri),
         {:ok, receipt} <- commit(facts) do
      publish_after_commit(facts)
      {:ok, receipt}
    end
  end

  def consume_before_start(_requested_uri, _handle), do: {:error, :invalid_agent_uri}

  defp validate(%{} = facts, requested_uri) do
    with {:ok, attempt_id} <- fetch(facts, :attempt_id),
         {:ok, agent_uri} <- fetch_uri(facts, :agent_uri),
         {:ok, root_uri} <- fetch_uri(facts, :root_uri),
         {:ok, workspace_uri} <- fetch_uri(facts, :workspace_uri),
         {:ok, _issuer_ref} <- fetch(facts, :issuer_ref),
         :ok <- validate_attempt(attempt_id),
         :ok <- validate_exact_agent(agent_uri, requested_uri),
         :ok <- validate_workspace(agent_uri, workspace_uri),
         :ok <- validate_root(root_uri, workspace_uri) do
      :ok
    end
  end

  defp validate(_facts, _requested_uri), do: {:error, :invalid_launch_facts}

  defp validate_attempt(attempt_id) when is_binary(attempt_id) and attempt_id != "", do: :ok
  defp validate_attempt(_attempt_id), do: {:error, :invalid_attempt_id}

  defp validate_exact_agent(%URI{} = agent_uri, %URI{} = requested_uri) do
    with true <- Ezagent.URI.bare_principal?(agent_uri),
         {:ok, "agent"} <- Ezagent.URI.type(agent_uri) do
      if agent_uri == requested_uri, do: :ok, else: {:error, :agent_uri_mismatch}
    else
      _ -> {:error, :invalid_agent_type}
    end
  end

  defp validate_exact_agent(_agent_uri, _requested_uri), do: {:error, :invalid_agent_type}

  defp validate_workspace(agent_uri, workspace_uri) do
    if same_uri?(Ezagent.URI.workspace_of(agent_uri), workspace_uri),
      do: :ok,
      else: {:error, :workspace_mismatch}
  end

  defp validate_root(root_uri, workspace_uri) do
    case Ezagent.URI.workspace_of(root_uri) do
      %URI{} = root_workspace ->
        if same_uri?(root_workspace, workspace_uri),
          do: :ok,
          else: {:error, :root_workspace_mismatch}

      :any ->
        {:error, :root_workspace_mismatch}
    end
  end

  defp commit(facts) do
    Repo.transaction(fn ->
      with :ok <- test_hook(:before_inventory, facts),
           {:ok, _} <-
             CreationInventory.record_exact(
               Repo,
               facts.attempt_id,
               facts.agent_uri,
               facts.root_uri,
               facts.workspace_uri
             ),
           :ok <- test_hook(:before_lineage, facts),
           {:ok, _} <-
             Ezagent.AgentLineage.record_exact(Repo, facts.agent_uri, facts.root_uri),
           :ok <- test_hook(:before_commit, facts) do
        receipt(facts)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  if Mix.env() == :test do
    defp test_hook(stage, facts), do: Ezagent.Agent.TestLaunchPersistence.hook(stage, facts)
  else
    defp test_hook(_stage, _facts), do: :ok
  end

  defp publish_after_commit(facts) do
    best_effort(fn -> @post_commit_publisher.publish(facts) end)
    :ok
  end

  defp best_effort(operation) do
    try do
      operation.()
    catch
      _kind, _reason -> :ok
    end
  end

  defp receipt(facts) do
    %{
      attempt_id: facts.attempt_id,
      agent_uri: facts.agent_uri,
      root_uri: facts.root_uri,
      workspace_uri: facts.workspace_uri
    }
  end

  defp fetch(facts, key) do
    case Map.fetch(facts, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :invalid_launch_facts}
    end
  end

  defp fetch_uri(facts, key) do
    case fetch(facts, key) do
      {:ok, %URI{} = uri} -> {:ok, uri}
      _ -> {:error, :invalid_launch_facts}
    end
  end

  defp same_uri?(left, right), do: URI.to_string(left) == URI.to_string(right)
end
