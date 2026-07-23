defmodule Ezagent.ProviderConnection.TestSessionAssuranceVerifier do
  @moduledoc false

  @behaviour Ezagent.ProviderConnection.SessionAssuranceVerifier

  alias Ezagent.ProviderConnection.Assurance

  @secret "d1-session-assurance-test-secret"

  def start_link(options \\ []) do
    observer = Keyword.fetch!(options, :observer)
    Agent.start_link(fn -> %{consumed: MapSet.new(), mode: :accept, observer: observer} end)
  end

  def set_mode(verifier, mode), do: Agent.update(verifier, &Map.put(&1, :mode, mode))

  def issue!(attrs) do
    {:ok, unsigned} = Assurance.new(Map.put(attrs, :signature, "unsigned"))
    %{unsigned | signature: signature(unsigned)}
  end

  @impl true
  def verify_and_consume(verifier, action, assurance, context) do
    case Agent.get(verifier, & &1.mode) do
      :raise ->
        raise("session-assurance-verifier-secret-sentinel")

      :throw ->
        throw({:session_assurance_verifier_secret, "session-assurance-verifier-secret-sentinel"})

      :exit ->
        exit({:session_assurance_verifier_secret, "session-assurance-verifier-secret-sentinel"})

      :arbitrary_error ->
        {:error,
         {:session_assurance_verifier_secret, "session-assurance-verifier-secret-sentinel"}}

      :wrong_result ->
        {:ok, "session-assurance-verifier-secret-sentinel"}

      _mode ->
        Agent.get_and_update(verifier, fn state ->
          {result, next_state} = consume(state, action, assurance, context)
          send(state.observer, {:session_assurance, action, assurance, result})
          {result, next_state}
        end)
    end
  end

  defp consume(%{mode: :reject} = state, _action, _assurance, _context),
    do: {{:error, :assurance_rejected}, state}

  defp consume(state, action, assurance, context) do
    replay_key = {assurance.reauth_ref, assurance.reauth_version}

    cond do
      not valid_context?(assurance, context) or action != assurance.action or
          assurance.signature != signature(assurance) ->
        {{:error, :assurance_rejected}, state}

      MapSet.member?(state.consumed, replay_key) ->
        {{:error, :assurance_replayed}, state}

      true ->
        {:ok, %{state | consumed: MapSet.put(state.consumed, replay_key)}}
    end
  end

  defp valid_context?(assurance, context) do
    context.owner_uri == assurance.owner_uri and
      context.workspace_uri == assurance.workspace_uri and
      context.grantee_uri == assurance.grantee_uri and
      context.connection_id == assurance.connection_id and
      context.connection_version == assurance.connection_version and
      DateTime.compare(context.verified_at, assurance.issued_at) in [:gt, :eq] and
      DateTime.compare(context.verified_at, assurance.expires_at) == :lt
  end

  defp signature(assurance) do
    payload =
      assurance
      |> Map.from_struct()
      |> Map.delete(:signature)
      |> :erlang.term_to_binary([:deterministic])

    :crypto.mac(:hmac, :sha256, @secret, payload)
  end
end
