defmodule Ezagent.Session.SocialwareInstallObligations do
  @moduledoc """
  Persistence boundary for recoverable Session socialware installation.

  This is an internal system-scope recovery queue, not a principal-facing read
  surface. Rows retain a required, indexed `workspace_uri`, while the global
  due scan intentionally crosses workspaces so one supervised sweeper can
  recover every tenant after node restart. Installation authorization is
  reconstructed from each row's workspace and actor before dispatch.
  """

  import Ecto.Query

  alias Ezagent.Session.SocialwareInstallObligation
  alias EzagentCore.Repo

  @doc false
  @spec ensure_pending(URI.t(), URI.t(), URI.t() | nil) ::
          {:ok, SocialwareInstallObligation.t()} | {:error, term()}
  def ensure_pending(%URI{} = session_uri, %URI{} = workspace_uri, actor_uri)
      when is_nil(actor_uri) or is_struct(actor_uri, URI) do
    identity = URI.to_string(session_uri)

    attrs = %{
      session_uri: identity,
      workspace_uri: URI.to_string(workspace_uri),
      actor_uri: actor_uri && URI.to_string(actor_uri)
    }

    case Repo.get_by(SocialwareInstallObligation, session_uri: identity) do
      nil ->
        %SocialwareInstallObligation{}
        |> SocialwareInstallObligation.create_changeset(attrs)
        |> Repo.insert(on_conflict: :nothing, conflict_target: :session_uri)
        |> case do
          {:ok, %SocialwareInstallObligation{id: nil}} -> ensure_existing_pending(identity, attrs)
          {:ok, obligation} -> {:ok, obligation}
          {:error, reason} -> {:error, reason}
        end

      %SocialwareInstallObligation{} ->
        ensure_existing_pending(identity, attrs)
    end
  end

  @doc false
  @spec get(pos_integer()) :: SocialwareInstallObligation.t() | nil
  def get(id), do: Repo.get(SocialwareInstallObligation, id)

  @doc false
  @spec get!(pos_integer()) :: SocialwareInstallObligation.t()
  def get!(id), do: Repo.get!(SocialwareInstallObligation, id)

  @doc false
  @spec get_by_session(URI.t()) :: SocialwareInstallObligation.t() | nil
  def get_by_session(%URI{} = session_uri) do
    Repo.get_by(SocialwareInstallObligation, session_uri: URI.to_string(session_uri))
  end

  @doc false
  @spec claim(pos_integer(), keyword()) ::
          {:ok, SocialwareInstallObligation.t() | :already_resolved} | {:error, term()}
  def claim(id, opts \\ []) when is_integer(id) and id > 0 do
    lease_seconds = Keyword.get(opts, :lease_seconds, 60)
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      obligation =
        Repo.one(
          from(o in SocialwareInstallObligation,
            where: o.id == ^id,
            lock: "FOR UPDATE"
          )
        )

      claim_locked(obligation, now, lease_seconds, Keyword.get(opts, :allow_failed, false))
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec record_failure(pos_integer(), term(), String.t()) ::
          {:ok, SocialwareInstallObligation.t()} | {:error, term()}
  def record_failure(id, reason, claim_token) when is_binary(claim_token) do
    obligation = get!(id)
    max_attempts = Application.get_env(:ezagent_domain_session, :install_max_attempts, 10)
    exhausted? = obligation.attempts >= max_attempts
    exponent = obligation.attempts |> max(1) |> min(7) |> Kernel.-(1)
    delay_seconds = min(Integer.pow(2, exponent), 60)

    conditional_transition(id, claim_token, %{
      status: if(exhausted?, do: :failed, else: :pending),
      last_error: inspect(reason),
      claim_token: nil,
      next_attempt_at:
        if(exhausted?, do: nil, else: DateTime.add(DateTime.utc_now(), delay_seconds, :second))
    })
  end

  @doc false
  @spec resolve(pos_integer(), String.t()) ::
          {:ok, SocialwareInstallObligation.t()} | {:error, term()}
  def resolve(id, claim_token) when is_binary(claim_token) do
    conditional_transition(id, claim_token, %{
      status: :resolved,
      last_error: nil,
      claim_token: nil,
      next_attempt_at: nil,
      resolved_at: DateTime.utc_now()
    })
  end

  @doc false
  @spec renew_claim(pos_integer(), String.t(), pos_integer()) ::
          {:ok, SocialwareInstallObligation.t()} | {:error, term()}
  def renew_claim(id, claim_token, lease_seconds)
      when is_integer(id) and id > 0 and is_binary(claim_token) and
             is_integer(lease_seconds) and lease_seconds > 0 do
    conditional_transition(id, claim_token, %{
      next_attempt_at: DateTime.add(DateTime.utc_now(), lease_seconds, :second)
    })
  end

  @doc false
  @spec list_due(pos_integer()) :: [SocialwareInstallObligation.t()]
  def list_due(limit) when is_integer(limit) and limit > 0 do
    now = DateTime.utc_now()

    Repo.all(
      from(o in SocialwareInstallObligation,
        where: o.status == :pending or o.status == :running,
        where: is_nil(o.next_attempt_at) or o.next_attempt_at <= ^now,
        order_by: [asc: o.inserted_at],
        limit: ^limit
      )
    )
  end

  defp ensure_existing_pending(identity, _attrs) do
    obligation = Repo.get_by!(SocialwareInstallObligation, session_uri: identity)
    {:ok, obligation}
  end

  defp claim_locked(nil, _now, _lease_seconds, _allow_failed), do: {:error, :not_found}

  defp claim_locked(
         %SocialwareInstallObligation{status: :resolved},
         _now,
         _lease_seconds,
         _allow_failed
       ),
       do: {:ok, :already_resolved}

  defp claim_locked(%SocialwareInstallObligation{status: :failed}, _now, _seconds, false),
    do: {:error, :failed}

  defp claim_locked(
         %SocialwareInstallObligation{status: :failed} = obligation,
         now,
         seconds,
         true
       ),
       do: claim_for_lease(obligation, now, seconds)

  defp claim_locked(
         %SocialwareInstallObligation{status: :running, next_attempt_at: lease} = obligation,
         now,
         seconds,
         _allow_failed
       )
       when not is_nil(lease) do
    if DateTime.compare(lease, now) == :gt,
      do: {:error, :already_claimed},
      else: claim_for_lease(obligation, now, seconds)
  end

  defp claim_locked(
         %SocialwareInstallObligation{status: :pending, next_attempt_at: due} = obligation,
         now,
         seconds,
         _allow_failed
       )
       when not is_nil(due) do
    if DateTime.compare(due, now) == :gt,
      do: {:error, :not_due},
      else: claim_for_lease(obligation, now, seconds)
  end

  defp claim_locked(%SocialwareInstallObligation{} = obligation, now, seconds, _allow_failed),
    do: claim_for_lease(obligation, now, seconds)

  defp claim_for_lease(obligation, now, lease_seconds) do
    obligation
    |> SocialwareInstallObligation.transition_changeset(%{
      status: :running,
      attempts: obligation.attempts + 1,
      last_error: nil,
      claim_token: Ecto.UUID.generate(),
      next_attempt_at: DateTime.add(now, lease_seconds, :second)
    })
    |> Repo.update()
  end

  defp conditional_transition(id, claim_token, attrs) do
    query =
      from(o in SocialwareInstallObligation,
        where: o.id == ^id,
        where: o.status == :running and o.claim_token == ^claim_token
      )

    case Repo.update_all(query, set: Map.to_list(attrs) ++ [updated_at: DateTime.utc_now()]) do
      {1, _} -> {:ok, get!(id)}
      {0, _} -> {:error, :stale_claim}
    end
  end
end
