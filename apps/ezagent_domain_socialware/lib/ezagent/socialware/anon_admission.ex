defmodule Ezagent.Socialware.AnonAdmission do
  @moduledoc """
  Anonymous participant admission for public socialware sessions.

  This is the domain primitive behind the web anon ingress flow. It owns the
  security-sensitive sequence:

    * mint a read-only anon user for a public session;
    * spawn the anon principal so its create-time join cap is live;
    * bind the anon to the session;
    * join the session as the anon itself;
    * mount participation caps best-effort after the join.

  Cookie parsing and HTTP response shaping stay in `EzagentWeb.Socialware.AnonIngress`.
  """

  alias Ezagent.Socialware.{AnonBinding, AnonUser}

  @type admission_source :: :minted | :reused
  @type result :: %{anon_uri: URI.t(), source: admission_source()}

  @doc """
  Mint and admit a fresh anonymous participant to `session_uri`.

  Fails closed on a non-public session or any mint/spawn/bind/join failure.
  Participation-cap mounting is explicitly best-effort after a successful join.
  """
  @spec admit_anonymous_participant(URI.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def admit_anonymous_participant(session_uri, opts \\ [])

  def admit_anonymous_participant(%URI{scheme: "session"} = session_uri, opts) do
    with {:ok, anon_uri} <- mint_for_public_session(session_uri, opts),
         :ok <- spawn_principal(anon_uri, opts),
         {:ok, _binding} <- AnonBinding.touch(anon_uri, session_uri, now(opts)),
         :ok <- join_as_anon(session_uri, anon_uri, opts) do
      {:ok, %{anon_uri: anon_uri, source: :minted}}
    end
  end

  def admit_anonymous_participant(other, _opts), do: {:error, {:not_a_session, other}}

  @doc """
  Refresh an existing cookie-bound anonymous participant.

  The caller supplies an anon URI already recovered from a signed cookie. This
  path refreshes the durable binding and respawns the principal if needed. The
  web shim deliberately falls back to `admit_anonymous_participant/2` if this
  refresh fails, so a stale/cold/reaping visitor gets a fresh anon identity.
  """
  @spec refresh_anonymous_participant(URI.t(), URI.t(), keyword()) ::
          {:ok, result()} | {:error, term()}
  def refresh_anonymous_participant(session_uri, anon_uri, opts \\ [])

  def refresh_anonymous_participant(
        %URI{scheme: "session"} = session_uri,
        %URI{} = anon_uri,
        opts
      ) do
    with {:ok, _binding} <- AnonBinding.touch(anon_uri, session_uri, now(opts)),
         :ok <- spawn_principal(anon_uri, opts) do
      {:ok, %{anon_uri: anon_uri, source: :reused}}
    end
  end

  def refresh_anonymous_participant(_session_uri, _anon_uri, _opts), do: {:error, :invalid_args}

  defp mint_for_public_session(session_uri, opts) do
    opts
    |> Keyword.get(:mint_for_public_session, &AnonUser.mint_for_public_session/1)
    |> call1(session_uri)
  end

  defp spawn_principal(anon_uri, opts) do
    opts
    |> Keyword.get(:spawn_principal, &Ezagent.Entity.spawn_principal/1)
    |> call1(anon_uri)
  end

  defp join_as_anon(session_uri, anon_uri, opts) do
    join_result =
      opts
      |> Keyword.get(:join, &dispatch_join/2)
      |> call2(session_uri, anon_uri)

    case join_result do
      :ok ->
        mount_participation(session_uri, anon_uri, opts)

      {:ok, _} ->
        mount_participation(session_uri, anon_uri, opts)

      {:error, _} = err ->
        err

      other ->
        {:error, {:bad_join_result, other}}
    end
  end

  defp dispatch_join(session_uri, anon_uri) do
    target = Ezagent.URI.with_action(session_uri, :session, :join)

    join_caps =
      anon_uri
      |> Ezagent.EntityCaps.load()
      |> Enum.filter(&join_cap_for?(&1, session_uri))

    if Enum.empty?(join_caps) do
      {:error, :missing_join_cap}
    else
      Ezagent.Invocation.dispatch(%Ezagent.Invocation{
        target: target,
        mode: :call,
        args: %{member: anon_uri},
        ctx: %{caller: anon_uri, caps: MapSet.new(join_caps), reply: :ignore},
        origin: :authenticated_external
      })
    end
  end

  defp join_cap_for?(%Ezagent.Capability{instance: %URI{}} = cap, session_uri) do
    cap.behavior == Ezagent.ActionSet.Session and cap.action == :join and
      Ezagent.URI.stable_key(cap.instance) == Ezagent.URI.stable_key(session_uri)
  end

  defp join_cap_for?(_cap, _session_uri), do: false

  defp mount_participation(session_uri, anon_uri, opts) do
    fun =
      Keyword.get(opts, :mount_participation, fn session, anon ->
        # D1 join 补发:统一走 MemberBackfill(participation tier + view caps +
        # mount operate keys;anon 未 confirmed → 只发 participation tier)。
        Ezagent.Socialware.MemberBackfill.backfill(session, anon)
      end)

    try do
      _ = fun.(session_uri, anon_uri)
      :ok
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp now(opts), do: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

  defp call1(fun, arg) when is_function(fun, 1), do: fun.(arg)
  defp call2(fun, arg1, arg2) when is_function(fun, 2), do: fun.(arg1, arg2)
end
