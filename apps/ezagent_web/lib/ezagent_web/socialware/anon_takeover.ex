defmodule EzagentWeb.Socialware.AnonTakeover do
  @moduledoc """
  Post-auth anon-to-confirmed login takeover orchestrator.

  Authority is the signed `socialware_anon` cookie plus the matching
  `AnonBinding` row. The cookie is verified in this web-layer module because it
  needs the endpoint secret; the session mutation itself is delegated to
  `session.merge_member`.
  """

  import Plug.Conn, only: [delete_resp_cookie: 2, fetch_cookies: 1]

  require Logger

  alias Ezagent.ActionSet.Session.Membership
  alias Ezagent.Socialware.{AnonBinding, AnonUser}
  alias EzagentWeb.Socialware.AnonCookie

  @doc """
  If `conn` carries a valid anon visitor cookie, merge that anon's session
  footprint into `confirmed_uri` and retire the anon. Otherwise returns `conn`
  unchanged.
  """
  @spec maybe_takeover(Plug.Conn.t(), URI.t()) :: Plug.Conn.t()
  def maybe_takeover(conn, %URI{} = confirmed_uri) do
    conn = fetch_cookies(conn)

    case Map.get(conn.cookies, AnonCookie.cookie_name()) do
      value when is_binary(value) ->
        takeover_from_cookie(conn, value, confirmed_uri)

      _ ->
        conn
    end
  end

  def maybe_takeover(conn, _confirmed_uri), do: conn

  defp takeover_from_cookie(conn, value, confirmed_uri) do
    case AnonCookie.verify_any(value) do
      {:ok, {anon_uri, session_uri}} ->
        case takeover(anon_uri, confirmed_uri, session_uri) do
          {:ok, _result} ->
            delete_resp_cookie(conn, AnonCookie.cookie_name())

          {:error, reason} ->
            Logger.warning(
              "AnonTakeover: takeover failed for anon=#{uri_to_string(anon_uri)} " <>
                "confirmed=#{uri_to_string(confirmed_uri)} " <>
                "session=#{uri_to_string(session_uri)}: #{inspect(reason)}"
            )

            conn
        end

      :error ->
        conn
    end
  end

  @doc false
  @spec takeover(URI.t(), URI.t(), URI.t()) :: {:ok, map()} | {:error, term()}
  def takeover(%URI{} = anon_uri, %URI{} = confirmed_uri, %URI{} = session_uri) do
    now = DateTime.utc_now()

    with :ok <- validate_anon(anon_uri),
         :ok <- validate_confirmed(confirmed_uri),
         :ok <- validate_binding(anon_uri, session_uri),
         {:ok, _claim} <- AnonBinding.claim_for_merge(anon_uri, confirmed_uri, now),
         :ok <- Ezagent.Entity.spawn_principal(confirmed_uri),
         :ok <- provision_join_authority(session_uri, confirmed_uri),
         {:ok, result} <- dispatch_merge_member(session_uri, anon_uri, confirmed_uri),
         {:ok, _} <- AnonBinding.mark_merge_state(anon_uri, :session_merged),
         {:ok, _} <- AnonBinding.mark_merge_state(anon_uri, :read_markers_repointed),
         {:ok, _count} <-
           Ezagent.MessageStore.relabel_identity(session_uri, anon_uri, confirmed_uri),
         {:ok, _} <- AnonBinding.mark_merge_state(anon_uri, :messages_relabelled),
         :ok <- mount_confirmed_caps(session_uri, confirmed_uri),
         {:ok, _} <- AnonBinding.mark_merge_state(anon_uri, :caps_mounted),
         :ok <- verify_convergence(session_uri, anon_uri, confirmed_uri),
         {:ok, _} <- AnonBinding.mark_merge_state(anon_uri, :verified),
         :ok <- retire_anon(anon_uri) do
      {:ok, result}
    end
  end

  def takeover(_, _, _), do: {:error, :invalid_args}

  defp validate_anon(%URI{} = anon_uri) do
    if AnonUser.anon_uri?(anon_uri), do: :ok, else: {:error, :not_anon}
  end

  defp validate_confirmed(%URI{} = confirmed_uri) do
    if Ezagent.Users.confirmed?(confirmed_uri),
      do: :ok,
      else: {:error, :not_confirmed}
  end

  defp validate_binding(%URI{} = anon_uri, %URI{} = session_uri) do
    session_str = uri_to_string(session_uri)

    case AnonBinding.get(anon_uri) do
      %AnonBinding{session_uri: ^session_str} -> :ok
      %AnonBinding{session_uri: other} -> {:error, {:session_mismatch, other}}
      nil -> {:error, :no_anon_binding}
    end
  end

  defp provision_join_authority(%URI{} = session_uri, %URI{} = confirmed_uri) do
    case Membership.provision_join_authority(session_uri, confirmed_uri) do
      :ok ->
        :ok

      {:error, :no_authority} ->
        grant_takeover_join_cap(session_uri, confirmed_uri)
    end
  end

  defp grant_takeover_join_cap(%URI{} = session_uri, %URI{} = confirmed_uri) do
    cap =
      Ezagent.Capability.cap(
        :session,
        Ezagent.ActionSet.Session,
        :join,
        session_uri,
        Ezagent.Capability.workspace_of(session_uri)
      )

    case Ezagent.Identity.Grant.grant_cap_via_router(
           confirmed_uri,
           cap,
           {:admin, Ezagent.URI.user(:system, :admin)},
           :sync
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "AnonTakeover: join-cap grant failed for confirmed=#{uri_to_string(confirmed_uri)} " <>
            "session=#{uri_to_string(session_uri)}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp dispatch_merge_member(%URI{} = session_uri, %URI{} = anon_uri, %URI{} = confirmed_uri) do
    target = Ezagent.URI.with_action(session_uri, :session, :merge_member)
    admin = Ezagent.Entity.User.admin_uri()

    with {:ok, signed_cap} <-
           Ezagent.Cap.issue_for_action({:admin, admin}, confirmed_uri, target) do
      case Ezagent.Invocation.dispatch(%Ezagent.Invocation{
             target: target,
             mode: :call,
             args: %{from: anon_uri, to: confirmed_uri},
             ctx: %{
               caller: confirmed_uri,
               caps: MapSet.new([signed_cap]),
               reply: :ignore
             },
             origin: :authenticated_external
           }) do
        {:ok, result} -> {:ok, result}
        :ok -> {:ok, %{}}
        {:error, _} = err -> err
      end
    end
  end

  defp mount_confirmed_caps(%URI{} = session_uri, %URI{} = confirmed_uri) do
    _ = Membership.mount_participation_caps(session_uri, confirmed_uri)
    :ok
  end

  defp verify_convergence(%URI{} = session_uri, %URI{} = anon_uri, %URI{} = confirmed_uri) do
    cond do
      member?(session_uri, anon_uri) ->
        {:error, :anon_still_member}

      not member?(session_uri, confirmed_uri) ->
        {:error, :confirmed_not_member}

      true ->
        :ok
    end
  end

  defp member?(%URI{} = session_uri, %URI{} = member_uri) do
    case Ezagent.Kind.get_slice(session_uri, :session) do
      {:ok, %{state: %{members: members}}} when is_map(members) ->
        Map.has_key?(members, member_uri)

      {:ok, %{members: members}} when is_map(members) ->
        Map.has_key?(members, member_uri)

      _ ->
        false
    end
  end

  defp retire_anon(%URI{} = anon_uri) do
    :ok = Ezagent.Users.delete(anon_uri)
    {:ok, _} = AnonBinding.delete(anon_uri)
    :ok
  end

  defp uri_to_string(%URI{} = uri), do: URI.to_string(uri)
end
