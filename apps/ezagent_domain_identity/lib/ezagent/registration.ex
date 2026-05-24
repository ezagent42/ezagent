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

  @doc """
  True if no User exists at `entity://user/<workspace>/<slug>`.

  PR-B 2026-05-24 (Allen, SPEC v2): slug uniqueness is now
  PER-WORKSPACE — `alice` in workspace `acme` and `alice` in
  workspace `beta` are distinct principals. Legacy callers without
  workspace context default to `"default"`; PR-C deletes
  `default` and forces all callers explicit.
  """
  @spec slug_available?(String.t(), String.t()) :: boolean()
  def slug_available?(slug, workspace \\ "default") when is_binary(slug) do
    is_nil(Users.get_by_uri("entity://user/#{workspace}/" <> slug))
  end

  @doc "Return the first free `<slug>`, `<slug>-2`, `<slug>-3`, ... variant in the workspace."
  @spec suggest_slug(String.t(), String.t()) :: String.t()
  def suggest_slug(slug, workspace \\ "default") when is_binary(slug) do
    if slug_available?(slug, workspace) do
      slug
    else
      Stream.iterate(2, &(&1 + 1))
      |> Enum.find_value(fn n ->
        candidate = "#{slug}-#{n}"
        if slug_available?(candidate, workspace), do: candidate
      end)
    end
  end

  @doc """
  True if `email`'s domain is in the legacy `registration_domains`
  AppSetting.

  **SPEC v2 PR-C (Allen 2026-05-24) — REMOVED from production path.**
  `Registration.email_allowed?/1` no longer consults this; the
  workspace's `magic_link_rule` rows are the sole gate. This function
  remains exported ONLY for tests / observability tools that want to
  inspect the legacy setting in a transitional environment. New code
  must call `email_allowed?/1`.
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
  SPEC v2 PR-C (Allen 2026-05-24) — the SOLE send-side gate.

  Returns true iff some workspace's `magic_link_rule` accepts the
  email. PR-A introduced this path; PR-C removes the back-compat
  `registration_domains` AppSetting fallback that v1/v2-transition
  required.
  """
  @spec email_allowed?(String.t()) :: boolean()
  def email_allowed?(email) when is_binary(email) do
    # `Ezagent.Workspace` lives in `ezagent_domain_workspace` which is
    # NOT a hard dep of `ezagent_domain_identity` (circular —
    # workspace depends on identity for cap defaults). `apply/3`
    # bypasses compile-time module dispatch; both apps are runtime
    # co-resident in dev/prod.
    if Code.ensure_loaded?(Ezagent.Workspace) and
         function_exported?(Ezagent.Workspace, :any_workspace_accepts?, 1) do
      apply(Ezagent.Workspace, :any_workspace_accepts?, [email])
    else
      false
    end
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

  PR-B 2026-05-24 (Allen, SPEC v2): now takes a `workspace` arg so
  the user lives in their CHOSEN workspace (from the onboarding LV),
  not a hardcoded `default`. Legacy 3-arity callers default to
  `"default"` for back-compat during the PR-B transition; PR-C deletes
  the `default` workspace which forces all callers to pass it.

  Returns `{:ok, uri}` or `{:error, :slug_taken | term()}`.
  """
  @spec create_principal(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, URI.t()} | {:error, term()}
  def create_principal(slug, display_name, email, workspace \\ "default")
      when is_binary(slug) and is_binary(display_name) and is_binary(email) and
             is_binary(workspace) do
    uri_str = "entity://user/#{workspace}/" <> slug
    uri = URI.parse(uri_str)

    cond do
      not slug_available?(slug, workspace) ->
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
            # PR-B 2026-05-24 — register the new user as a member of
            # their chosen workspace. Lazy dispatch via apply/3 to
            # avoid identity → workspace compile-time circular dep
            # (same pattern as `email_allowed?/1`).
            maybe_add_workspace_member(workspace, uri)
            {:ok, uri}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp maybe_add_workspace_member(workspace, %URI{} = user_uri) do
    if Code.ensure_loaded?(Ezagent.Workspace) and
         function_exported?(Ezagent.Workspace, :add_member, 2) do
      _ = apply(Ezagent.Workspace, :add_member, [workspace, user_uri])
    end

    :ok
  end
end
