defmodule Ezagent.Registration do
  @moduledoc """
  Username & Auth M3 — email-magic-link registration logic.

  Pure-ish coordination over `Ezagent.Users`, `Ezagent.Entity.Profile`,
  `Ezagent.AppSettings`, and `Ezagent.Entity.spawn_principal/1`.

  ## Slug = URI = immutable identity

  `derive_slug/1` proposes a URL-safe slug from an email. The slug is
  editable ONLY before `create_principal/3` is called — once a User
  exists, `entity://user/<slug>` is the system primary key and is
  frozen (design铁律 #1). After that, `display_name` is the mutable
  knob, not the slug.
  """

  alias Ezagent.AppSettings
  alias Ezagent.Entity.Profile
  alias Ezagent.Users

  @doc "Propose a URL-safe slug from an email's local part."
  @spec derive_slug(String.t()) :: String.t()
  def derive_slug(email) when is_binary(email) do
    email
    |> String.split("@", parts: 2)
    |> List.first()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "user"
      s -> s
    end
  end

  @doc "True if no User exists at `entity://user/default/<slug>`."
  @spec slug_available?(String.t()) :: boolean()
  def slug_available?(slug) when is_binary(slug) do
    # Phase 9 PR-2 (SPEC v3 §3): entity URIs carry a workspace
    # segment. Until tenant-aware registration lands (PR-5), slugs
    # default to the `default` workspace.
    is_nil(Users.get_by_uri("entity://user/default/" <> slug))
  end

  @doc "Return the first free `<slug>`, `<slug>-2`, `<slug>-3`, ... variant."
  @spec suggest_slug(String.t()) :: String.t()
  def suggest_slug(slug) when is_binary(slug) do
    if slug_available?(slug) do
      slug
    else
      Stream.iterate(2, &(&1 + 1))
      |> Enum.find_value(fn n ->
        candidate = "#{slug}-#{n}"
        if slug_available?(candidate), do: candidate
      end)
    end
  end

  @doc """
  True if `email`'s domain is in the configured `registration_domains`.

  **SPEC 2026-05-24 v2 PR-A (Allen) — DEPRECATED**. The flat global
  `registration_domains` AppSetting is being replaced by per-workspace
  `magic_link_rule` rows (`Ezagent.Workspace.MagicLinkRule`). PR-A
  introduces the new path via `email_allowed?/1` below; the old path
  remains during transition and is consulted as a fallback for
  pre-existing deployments. PR-B removes the AppSetting consultation
  entirely after the registration flow is rewritten.
  """
  @spec domain_allowed?(String.t()) :: boolean()
  def domain_allowed?(email) when is_binary(email) do
    domains = AppSettings.get("registration_domains") || []

    case String.split(email, "@", parts: 2) do
      [_, domain] -> String.downcase(String.trim(domain)) in Enum.map(domains, &String.downcase/1)
      _ -> false
    end
  end

  def domain_allowed?(_), do: false

  @doc """
  SPEC 2026-05-24 v2 PR-A (Allen) — the NEW send-side gate.

  `email_allowed?/1` returns true iff EITHER:
  1. Some workspace's `magic_link_rule` accepts the email (the new
     per-workspace gate), OR
  2. The legacy `registration_domains` AppSetting still includes the
     email's domain (back-compat — DB wipe means this is empty in
     practice, but the fallback keeps the test fixtures green during
     the PR-B transition).

  Once PR-B lands and removes the AppSetting path, this function
  collapses to `Ezagent.Workspace.any_workspace_accepts?/1`.
  """
  @spec email_allowed?(String.t()) :: boolean()
  def email_allowed?(email) when is_binary(email) do
    # `Ezagent.Workspace` lives in `ezagent_domain_workspace` which
    # is NOT a hard dep of `ezagent_domain_identity` (circular —
    # workspace depends on identity for cap defaults). Lazy lookup
    # via `Code.ensure_loaded?` keeps the boundary one-way at
    # compile time; at runtime both apps are always co-resident.
    # `apply/3` bypasses compile-time module dispatch — the workspace
    # module is loaded at runtime in dev/prod (umbrella co-resident)
    # but identity's compile-time dep graph stays clean.
    workspace_accept? =
      if Code.ensure_loaded?(Ezagent.Workspace) and
           function_exported?(Ezagent.Workspace, :any_workspace_accepts?, 1) do
        apply(Ezagent.Workspace, :any_workspace_accepts?, [email])
      else
        false
      end

    workspace_accept? or domain_allowed?(email)
  end

  def email_allowed?(_), do: false

  @doc "Resolve an email to an existing principal URI, or `:none`."
  @spec principal_for_email(String.t()) :: {:ok, URI.t()} | :none
  def principal_for_email(email) when is_binary(email) do
    case Profile.by_email(email) do
      %Profile{entity_uri: uri_str} -> {:ok, URI.parse(uri_str)}
      nil -> :none
    end
  end

  @doc """
  Create a brand-new principal: `users` row (password-less, default
  caps), `entity_profiles` row, and a spawned + cap-hydrated User Kind.

  Returns `{:ok, uri}` or `{:error, :slug_taken | term()}`.
  """
  @spec create_principal(String.t(), String.t(), String.t()) ::
          {:ok, URI.t()} | {:error, term()}
  def create_principal(slug, display_name, email)
      when is_binary(slug) and is_binary(display_name) and is_binary(email) do
    # Phase 9 PR-2 (SPEC v3 §3): entity URIs carry a workspace
    # segment; registration defaults to the `default` workspace
    # until tenant-aware registration lands (PR-5).
    uri_str = "entity://user/default/" <> slug
    uri = URI.parse(uri_str)

    cond do
      not slug_available?(slug) ->
        {:error, :slug_taken}

      true ->
        # users-row + profile-row insert in ONE transaction: if the
        # profile insert fails (e.g. concurrent email collision), the
        # users row rolls back — no orphan principal. The Kind spawn
        # happens only AFTER commit (a process can't be rolled back).
        txn =
          EzagentCore.Repo.transaction(fn ->
            with {:ok, _user} <- Users.create(uri, nil, []),
                 {:ok, _profile} <-
                   Profile.upsert(%{
                     entity_uri: uri_str,
                     display_name: String.trim(display_name),
                     email: email
                   }) do
              :created
            else
              {:error, reason} -> EzagentCore.Repo.rollback(reason)
            end
          end)

        case txn do
          {:ok, :created} ->
            :ok = Ezagent.Entity.spawn_principal(uri)
            {:ok, uri}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end
end
