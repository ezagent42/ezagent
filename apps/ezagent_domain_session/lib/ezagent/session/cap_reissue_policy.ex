defmodule Ezagent.Session.CapReissuePolicy do
  @moduledoc false

  @behaviour Ezagent.Cap.ReissuePolicy

  alias Ezagent.Capability

  @impl true
  def classify(%Capability{
        kind: :session,
        behavior: behavior,
        instance: %URI{scheme: "session"}
      })
      when behavior in [Ezagent.ActionSet.Session, Ezagent.ActionSet.Publisher.SessionImpl],
      do: {:ok, :session_participation}

  def classify(%Capability{
        kind: :agent,
        behavior: behavior,
        action: action,
        instance: {:spawned_by, %URI{}}
      })
      when {behavior, action} in [
             {Ezagent.ActionSet.Sandbox, :destroy},
             {Ezagent.ActionSet.Terminable, :terminate}
           ],
      do: {:ok, :session_owner_teardown}

  def classify(%Capability{
        kind: :session_template,
        behavior: Ezagent.ActionSet.Template,
        action: :any,
        instance: {:within_workspace, %URI{scheme: "workspace"}}
      }),
      do: {:ok, :session_template_owner}

  def classify(%Capability{
        kind: :session,
        behavior: Ezagent.ActionSet.OrchestratorAdmin,
        action: :restart,
        instance: %URI{scheme: "session"}
      }),
      do: {:ok, :orchestrator_admin}

  def classify(%Capability{
        kind: kind,
        behavior: :any,
        action: :any,
        instance: {scope, %URI{}}
      })
      when kind in [:session, :agent] and scope in [:within_session, :spawned_by],
      do: {:ok, :orchestrator_delegation}

  def classify(%Capability{
        kind: kind,
        behavior: Ezagent.ActionSet.Template,
        action: :any,
        instance: {:within_workspace, %URI{scheme: "workspace"}}
      })
      when kind in [:session_template, :agent_template],
      do: {:ok, :orchestrator_template}

  def classify(_cap), do: :not_mine

  @impl true
  def reissue_action(%{__struct__: Capability, granted_by: %URI{} = issuer} = cap, _receiver) do
    case classify(cap) do
      {:ok, class} when class in [:session_participation, :session_owner_teardown] ->
        {:reissue, {:rule, :session_participation, issuer}}

      {:ok, class}
      when class in [:session_template_owner, :orchestrator_admin, :orchestrator_template] ->
        {:reissue, {:rule, :template_materialize, issuer}}

      {:ok, :orchestrator_delegation} ->
        {:reissue, {:genesis, issuer}}

      :not_mine ->
        {:quarantine, :not_session_owned}
    end
  end

  def reissue_action(_cap, _receiver), do: {:quarantine, :missing_session_issuer}
end
