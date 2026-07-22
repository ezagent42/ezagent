defmodule Ezagent.ActionSet.SupervisorApproval do
  @moduledoc """
  P9 B2 supervisor approval/quorum workflow for socialware sessions.

  The durable assignment of holders lives in `Ezagent.Workspace` (workspace
  scope). This behavior records per-turn verdicts in the session and rejects
  stale holders by re-checking the current workspace assignment at submit time.
  """

  use Ezagent.Lifecycle, state_slice: :supervisor_approvals

  action(:submit_verdict,
    args: %{
      turn_id: :string,
      responsibility: :string,
      verdict: :atom,
      quorum_policy: :map,
      arbiter: {:option, :string}
    },
    returns: %{status: :atom},
    caps: [:submit_verdict],
    modes: [:call],
    description: "submit a supervisor verdict and evaluate quorum"
  )

  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{verdicts: %{}}}

  @spec data_owner(URI.t() | :any | term()) :: URI.t() | :any | :no_owner
  def data_owner(%URI{scheme: "session"} = session_uri) do
    Ezagent.ActionSet.Session.data_owner(session_uri)
  end

  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner

  @spec handle_submit_verdict(map(), map()) :: {:ok, map(), [term()]} | {:error, term()}
  def handle_submit_verdict(
        %{
          turn_id: turn_id,
          responsibility: responsibility,
          verdict: verdict,
          quorum_policy: quorum_policy
        } = args,
        ctx
      )
      when is_binary(turn_id) and is_binary(responsibility) and is_map(quorum_policy) do
    holder = Map.get(ctx, :authenticated_principal)
    session_uri = Map.get(ctx, :self_uri)
    workspace_uri = workspace_uri_for_session(session_uri)

    with %URI{} <- holder,
         %URI{} <- workspace_uri,
         true <-
           Ezagent.Workspace.ResponsibilityAssignment.assigned?(
             workspace_uri,
             responsibility,
             holder
           ),
         :ok <- Ezagent.Session.Membership.authorize(%{}, holder, session_uri, holder) do
      verdicts = ctx.read.(:verdicts, %{})
      key = {turn_id, responsibility}
      entry = Map.get(verdicts, key, %{verdicts: %{}})

      entry =
        entry
        |> put_in([:verdicts, Ezagent.URI.stable_key(holder)], normalize_verdict(verdict))
        |> Map.put(:quorum_policy, normalize_policy(quorum_policy))
        |> Map.put(:arbiter, Map.get(args, :arbiter))

      holders = Ezagent.Workspace.ResponsibilityAssignment.holders(workspace_uri, responsibility)
      evaluated = evaluate(entry, holders)
      entry = Map.merge(entry, evaluated)

      {:ok, evaluated, [{:set, :verdicts, Map.put(verdicts, key, entry)}]}
    else
      false -> {:error, :stale_holder}
      {:error, :unauthorized} -> {:error, :not_session_member}
      _ -> {:error, :invalid_verdict_context}
    end
  end

  defp normalize_verdict(verdict) when verdict in [:approve, :reject], do: verdict
  defp normalize_verdict(verdict) when verdict in ["approve", "approved"], do: :approve
  defp normalize_verdict(verdict) when verdict in ["reject", "rejected"], do: :reject
  defp normalize_verdict(other), do: other

  defp normalize_policy(%{type: type} = policy),
    do: Map.put(policy, :type, normalize_policy_type(type))

  defp normalize_policy(%{"type" => type} = policy),
    do: %{type: normalize_policy_type(type), n: Map.get(policy, "n")}

  defp normalize_policy(_), do: %{type: :any_one}

  defp normalize_policy_type(type) when type in [:any_one, :majority, :n_of_m], do: type
  defp normalize_policy_type("majority"), do: :majority
  defp normalize_policy_type("n_of_m"), do: :n_of_m
  defp normalize_policy_type(_), do: :any_one

  defp evaluate(%{verdicts: verdicts, quorum_policy: policy, arbiter: arbiter}, holders) do
    holder_keys = MapSet.new(Enum.map(holders, &Ezagent.URI.stable_key/1))

    current_votes =
      verdicts
      |> Enum.filter(fn {holder, _verdict} -> MapSet.member?(holder_keys, holder) end)
      |> Map.new()

    approvals = count_verdict(current_votes, :approve)
    rejections = count_verdict(current_votes, :reject)
    threshold = threshold(policy, max(length(holders), 1))

    cond do
      approvals > 0 and rejections > 0 and is_binary(arbiter) and arbiter != "" ->
        %{
          status: :escalated,
          receiver: {:role, arbiter},
          approvals: approvals,
          rejections: rejections
        }

      approvals >= threshold ->
        %{status: :approved, approvals: approvals, rejections: rejections}

      rejections >= threshold ->
        %{status: :rejected, approvals: approvals, rejections: rejections}

      true ->
        %{status: :pending, approvals: approvals, rejections: rejections}
    end
  end

  defp count_verdict(votes, verdict), do: Enum.count(votes, fn {_holder, v} -> v == verdict end)

  defp threshold(%{type: :majority}, holder_count), do: div(holder_count, 2) + 1

  defp threshold(%{type: :n_of_m} = policy, _holder_count) do
    case Map.get(policy, :n) || Map.get(policy, "n") do
      n when is_integer(n) and n > 0 -> n
      _ -> 1
    end
  end

  defp threshold(_policy, _holder_count), do: 1

  defp workspace_uri_for_session(%URI{} = session_uri) do
    case Ezagent.WorkspaceRegistry.lookup(session_uri) do
      {:ok, %URI{} = workspace_uri} -> workspace_uri
      :error -> Ezagent.Capability.workspace_of(session_uri)
    end
  end

  defp workspace_uri_for_session(_), do: nil
end
