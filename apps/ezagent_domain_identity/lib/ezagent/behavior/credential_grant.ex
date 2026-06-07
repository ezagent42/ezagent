defmodule Ezagent.Behavior.CredentialGrant do
  @moduledoc """
  Cap-checked credential grant management for Agent Kinds.

  The durable grant row lives in `Ezagent.Credential.GrantRow`. This Behavior is the
  operator-facing revoke chokepoint so LiveViews and CLI-like callers do not write the
  grant table directly.
  """

  use Ezagent.Lifecycle

  alias Ezagent.Credential.GrantRow

  action(:revoke_credential_grant,
    args: %{},
    returns: %{agent_uri: :string, revoked: :boolean},
    caps: [{:revoke_credential_grant, kind: :agent}],
    modes: [:call],
    description: "Revoke the credential grant for this agent and restart it into fail-loud auth."
  )

  def required_caps do
    %{
      revoke_credential_grant:
        Ezagent.Capability.cap(:agent, __MODULE__, :revoke_credential_grant)
    }
  end

  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{revocations: 0}}

  def data_owner(_), do: :any

  def handle_revoke_credential_grant(_args, ctx) do
    self_uri = Map.fetch!(ctx, :self_uri)
    kind_module = Map.fetch!(ctx, :kind_module)
    agent_uri = URI.to_string(self_uri)
    prev = ctx.read.(:revocations, 0)

    case GrantRow.revoke(agent_uri) do
      {:ok, row} ->
        {:ok, %{agent_uri: agent_uri, revoked: true},
         [
           {:set, :revocations, prev + 1},
           {:emit, :credential_grant_revoked,
            %{
              agent_uri: agent_uri,
              credential_source_uri: row.credential_source_uri,
              version: row.version,
              revoked_at: row.revoked_at
            }},
           {:effect, {Ezagent.Behavior.Terminable, :schedule_termination},
            [self_uri, kind_module]}
         ]}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
