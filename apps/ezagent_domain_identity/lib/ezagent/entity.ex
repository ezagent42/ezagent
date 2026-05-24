defmodule Ezagent.Entity do
  @moduledoc """
  Entity facade — entity-agnostic auth + identity helpers (PR #142,
  `entity-agnostic-architecture-reflection.md` §4 S-1).

  Today every dispatch surface (login form, CLI bearer-token, future
  agent-driven `/admin`) needs to "verify this URI presented this
  secret and return its caps". Before SPEC v2 this was split:
  `user://` URIs went through bcrypt against `users.password_hash`;
  `agent://` URIs had no equivalent auth step (they were spawned by
  capability).

  After PR #141 the `entity://` scheme unifies User + Agent; after
  PR #142 this module is the unified auth path. Dispatches by URI
  shape:

  - `entity://user/<name>` + password → bcrypt path (delegates to
    `Ezagent.Users.verify_password/2`)
  - `entity://agent/<flavor>_<name>` + token → entity_tokens path
    (delegates to `Ezagent.Entity.Token.verify/2`)
  - other entity URIs / non-entity schemes → `{:error, {:unsupported_entity_uri, uri}}`

  Returns `{:ok, %{caps: MapSet.t(Ezagent.Capability.t())}}` on
  success.
  """

  alias Ezagent.Entity.Token
  alias Ezagent.Users

  @type result :: {:ok, %{caps: MapSet.t(Ezagent.Capability.t())}} | {:error, term()}

  @doc """
  Authenticate `uri` with `secret`. Dispatch is by URI host:

  - `host == "user"` → bcrypt against `users.password_hash`
  - `host == "agent"` → bearer-token verify against `entity_tokens`

  Returns:
  - `{:ok, %{caps: MapSet.t()}}` on success
  - `{:error, :no_such_user}` — user URI unknown
  - `{:error, :no_such_entity}` — agent URI has no tokens
  - `{:error, :invalid_credentials}` — wrong password / wrong token
  - `{:error, {:unsupported_entity_uri, uri}}` — non-entity URI
  """
  @spec authenticate(URI.t(), String.t()) :: result()
  def authenticate(uri, secret)

  def authenticate(%URI{scheme: "entity", host: "user", path: "/" <> _name} = uri, secret)
      when is_binary(secret) do
    uri_str = URI.to_string(uri)

    cond do
      is_nil(Users.get_by_uri(uri_str)) ->
        # Run a dummy verify to avoid timing leak.
        Bcrypt.no_user_verify()
        {:error, :no_such_user}

      # Codex CLI/GUI audit 2026-05-24 HIGH-1: user URIs accept BOTH
      # passwords (for the /login form) AND bearer tokens (for CLI
      # access). Token.mint/2 already accepts user URIs; this
      # completes the auth side. Try token first (cheaper; only checks
      # entity_tokens table); fall through to password.
      match?({:ok, _}, Token.verify(uri, secret)) ->
        ensure_spawned(uri)
        caps = Ezagent.Identity.list_caps_for(uri)
        {:ok, %{caps: caps}}

      Users.verify_password(uri_str, secret) ->
        ensure_spawned(uri)
        caps = Ezagent.Identity.list_caps_for(uri)
        {:ok, %{caps: caps}}

      true ->
        {:error, :invalid_credentials}
    end
  end

  def authenticate(%URI{scheme: "entity", host: "agent", path: "/" <> _name} = uri, token)
      when is_binary(token) do
    Token.verify(uri, token)
  end

  def authenticate(%URI{} = uri, _secret), do: {:error, {:unsupported_entity_uri, uri}}

  @doc """
  Idempotently spawn the Kind for `uri`, hydrating its caps from the
  DB row when this call is the one that creates it. Safe to call when
  the Kind is already alive. Used by registration + magic-link login.
  """
  @spec spawn_principal(URI.t()) :: :ok
  def spawn_principal(%URI{} = uri), do: ensure_spawned(uri)

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
    case Ezagent.KindRegistry.lookup(uri) do
      {:ok, _pid} ->
        :ok

      :error ->
        spawn_with_hydrated_caps(uri)
    end
  end

  defp spawn_with_hydrated_caps(%URI{} = uri) do
    uri_str = URI.to_string(uri)

    case Users.get_by_uri(uri_str) do
      %{caps: caps_list} when is_list(caps_list) and caps_list != [] ->
        # Reach past the generic spawn fn so we can pass initial_caps.
        # The spawn fn registered in EzagentDomainIdentity.Application
        # uses `MapSet.new()`, which is correct for "no row to hydrate
        # from" but wrong for our freshly-provisioned user.
        #
        # V1 prevention (Allen 2026-05-21): route via Ezagent.Kind.spawn/2.
        # User Kind's supervisor/0 callback points at
        # `EzagentDomainIdentity.Application.UserSupervisor` so the
        # destination is preserved without naming it here.
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
