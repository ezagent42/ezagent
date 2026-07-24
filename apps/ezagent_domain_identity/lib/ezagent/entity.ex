defmodule Ezagent.Entity do
  @moduledoc """
  Entity facade — password-login and identity helpers (PR #142,
  `entity-agnostic-architecture-reflection.md` §4 S-1).

  Today every dispatch surface (login form, CLI bearer-token, future
  agent-driven `/admin`) needs to "verify this URI presented this
  secret and return its caps". Before SPEC v2 this was split:
  `user://` URIs went through bcrypt against `users.password_hash`;
  `agent://` URIs had no equivalent auth step (they were spawned by
  capability).

  Bearer credentials resolve through `Ezagent.Authentication.authenticate/1`.
  This module deliberately keeps password login separate: a user URI and human
  password authenticate an interactive login that may mint a PAT, but passwords
  are never accepted by the per-operation credential resolver.
  """

  alias Ezagent.Users

  @type result :: {:ok, %{caps: MapSet.t(Ezagent.Capability.t())}} | {:error, term()}

  @doc "Authenticate an interactive human login with a user URI and password only."
  @spec authenticate_password(URI.t(), String.t()) :: result()
  def authenticate_password(%URI{scheme: "entity"} = uri, password)
      when is_binary(password) do
    if entity_type?(uri, :user) do
      authenticate_user_password(uri, password)
    else
      {:error, {:unsupported_entity_uri, uri}}
    end
  end

  def authenticate_password(%URI{} = uri, _password),
    do: {:error, {:unsupported_entity_uri, uri}}

  defp authenticate_user_password(%URI{} = uri, password) do
    uri_str = URI.to_string(uri)

    case Users.get_by_uri(uri_str) do
      nil ->
        # Run a dummy verify to avoid timing leak.
        Bcrypt.no_user_verify()
        {:error, :no_such_user}

      %{disabled_at: %DateTime{}} ->
        Bcrypt.no_user_verify()
        {:error, :disabled}

      _user ->
        if Users.verify_password(uri_str, password) do
          ensure_spawned(uri)
          {:ok, %{caps: Ezagent.Identity.list_caps_for(uri)}}
        else
          {:error, :invalid_credentials}
        end
    end
  end

  defp entity_type?(%URI{} = uri, type) do
    Ezagent.URI.type?(uri, type) and match?({:ok, _name}, Ezagent.URI.name(uri))
  end

  @doc """
  Idempotently spawn the Kind for `uri`, hydrating its caps from the
  DB row when this call is the one that creates it. Safe to call when
  the Kind is already alive. Used by registration + magic-link login.
  """
  @spec spawn_principal(URI.t()) :: :ok | {:error, :revocation_pending}
  def spawn_principal(%URI{} = uri) do
    if Ezagent.Identity.Offboarding.RevocationFence.fenced?(uri) do
      {:error, :revocation_pending}
    else
      ensure_spawned(uri)
    end
  end

  # Login goes through `Ezagent.Identity.list_caps_for/1`, which returns
  # an empty MapSet if the principal's Kind isn't spawned. In production
  # every persisted User is spawned at boot — but a freshly-created
  # User (mid-test, or just provisioned via `mix ezagent.user.create`)
  # may not be live yet. Idempotently ensure spawn here so the caps
  # lookup returns the real cap set.
  #
  # When we have to spawn the Kind ourselves, we also hydrate its
  # initial caps from the DB row's `caps_json` — otherwise the
  # demand-spawn path would silently produce an empty MapSet for any
  # user provisioned after boot.
  defp ensure_spawned(%URI{} = uri) do
    if Ezagent.Kind.alive?(uri) do
      :ok
    else
      spawn_with_hydrated_caps(uri)
    end
  end

  defp spawn_with_hydrated_caps(%URI{} = uri) do
    case Ezagent.EntityCaps.load_persisted(uri) do
      caps_list when is_list(caps_list) and caps_list != [] ->
        # Reach past the generic spawn fn so we can pass initial_caps.
        # The spawn fn registered in EzagentDomainIdentity.Application
        # uses `MapSet.new()`, which is correct for "no row to hydrate
        # from" but wrong for our freshly-provisioned user.
        #
        # V1 prevention (Allen 2026-05-21): route via Ezagent.Kind.spawn/2.
        # User Kind's supervisor/0 callback points at
        # `EzagentDomainIdentity.Application.UserSupervisor` so the
        # destination is preserved without naming it here.
        # derivation-edge: rehydration-only Users row already owns its edge
        Ezagent.Kind.spawn(Ezagent.Entity.User, %{
          uri: uri,
          initial_caps: MapSet.new(caps_list)
        })
        |> case do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          _ -> :ok
        end

      _ ->
        # No DB row → fall back to generic spawn (which the User-only
        # spawn fn handles). This path runs for agent URIs too.
        case Ezagent.SpawnRegistry.spawn(uri) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          _ -> :ok
        end
    end
  end
end
