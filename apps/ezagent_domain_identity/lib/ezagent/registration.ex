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
  workspace `beta` are distinct principals. PR-F (this PR) removes
  the legacy `\\ "default"` default — all callers MUST pass an
  explicit workspace now that the `default` workspace itself is
  gone (PR-C #295).
  """
  @spec slug_available?(String.t(), String.t()) :: boolean()
  def slug_available?(slug, workspace) when is_binary(slug) and is_binary(workspace) do
    is_nil(Users.get_by_uri(Ezagent.URI.user(workspace, slug)))
  end

  @doc "Return the first free `<slug>`, `<slug>-2`, `<slug>-3`, ... variant in the workspace."
  @spec suggest_slug(String.t(), String.t()) :: String.t()
  def suggest_slug(slug, workspace) when is_binary(slug) and is_binary(workspace) do
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
      %Profile{entity_uri: uri_str} -> {:ok, Ezagent.URI.new!(uri_str)}
      nil -> :none
    end
  end

  @doc """
  Create a brand-new principal: `users` row (password-less, default
  caps), `entity_profiles` row, and a spawned + cap-hydrated User Kind.

  PR-B 2026-05-24 (Allen, SPEC v2): takes a `workspace` arg so the
  user lives in their CHOSEN workspace (from the onboarding LV). PR-F
  (this PR) removes the legacy `\\ "default"` default — all callers
  MUST pass an explicit workspace now that the `default` workspace
  itself is gone (PR-C #295).

  Returns `{:ok, uri}` or `{:error, :slug_taken | term()}`.
  """
  @spec create_principal(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, URI.t()} | {:error, term()}
  def create_principal(slug, display_name, email, workspace)
      when is_binary(slug) and is_binary(display_name) and is_binary(email) and
             is_binary(workspace) do
    uri = Ezagent.URI.user(workspace, slug)

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
                     entity_uri: Ezagent.URI.stable_key(uri),
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

  # ── task #87 self-registration (email + password) ───────────────────────

  @doc """
  Self-registration with a password (task #87 Decision 10). Creates an
  **unverified** principal (`email_verified: false`) with a password hash, in a
  workspace decided by `opts`:

  - `invite_code: code` — consume one use of the code (atomic, inside the
    transaction) and join the code's **authoritative** workspace under the code
    issuer's authority (`add_member/3`, NOT the trusted `/2`).
  - `mode: :open_self_serve` — create a fresh `<slug>-<random>` workspace for the
    registrant (founder self-membership via `/2`).

  Consume + user/profile creation run in ONE `Repo.transaction` so a use is never
  burned without a user and a user is never created without consuming a use
  (Codex plan-review #2). Returns `{:ok, uri}` or `{:error, reason}`. Does NOT
  reuse `create_principal/4` (that makes a passwordless, already-verified row —
  Codex #5).
  """
  @spec register_with_password(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, URI.t()} | {:error, term()}
  def register_with_password(email, password, display_name, opts)
      when is_binary(email) and is_binary(password) and is_binary(display_name) do
    email = email |> String.trim() |> String.downcase()

    with :ok <- ensure_email_free(email),
         {:ok, plan} <- registration_plan(email, opts) do
      slug = suggest_slug(derive_slug(email), plan.workspace_name)
      uri = Ezagent.URI.user(plan.workspace_name, slug)

      txn =
        EzagentCore.Repo.transaction(fn ->
          with :ok <- plan.consume.(),
               {:ok, _user} <- Users.create(uri, password, [], email_verified: false),
               {:ok, _profile} <-
                 Profile.upsert(%{
                   entity_uri: Ezagent.URI.stable_key(uri),
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
          plan.join.(uri)
          {:ok, uri}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp ensure_email_free(email) do
    case Profile.by_email(email) do
      nil -> :ok
      %Profile{} -> {:error, :email_taken}
    end
  end

  # Build the per-mode plan: which workspace, how to consume (invite), how to join.
  defp registration_plan(email, opts) do
    cond do
      code = opts[:invite_code] ->
        case Ezagent.Entity.InviteCode.validate(code) do
          {:ok, row} ->
            ws_name = row.workspace_uri |> Ezagent.URI.new!() |> Ezagent.URI.workspace_name!()

            {:ok,
             %{
               workspace_name: ws_name,
               consume: fn ->
                 case Ezagent.Entity.InviteCode.consume(code) do
                   {:ok, _} -> :ok
                   {:error, r} -> {:error, {:invite, r}}
                 end
               end,
               # Membership granted under the CODE ISSUER's authority (Codex #3,
               # Decision #154 no-unowned-permissions) — not workspace self-auth.
               join: fn uri -> join_under_issuer(ws_name, uri, row.created_by) end
             }}

          {:error, r} ->
            {:error, {:invite, r}}
        end

      opts[:mode] == :open_self_serve ->
        ws_name = "#{String.slice(derive_slug(email), 0, 20)}-#{random_suffix()}"

        case create_self_serve_workspace(ws_name, email) do
          :ok ->
            {:ok,
             %{
               workspace_name: ws_name,
               consume: fn -> :ok end,
               # Founder of a brand-new workspace joins it under workspace
               # self-authority (/2) — no privilege bypass since they own it.
               join: fn uri -> founder_join(ws_name, uri) end
             }}

          {:error, r} ->
            {:error, {:workspace, r}}
        end

      true ->
        {:error, :no_registration_target}
    end
  end

  defp join_under_issuer(ws_name, %URI{} = user_uri, issuer_str) when is_binary(issuer_str) do
    if workspace_loaded?(:add_member, 3) do
      issuer = Ezagent.URI.new!(issuer_str)
      ctx = %{caller: issuer, caps: Ezagent.Identity.list_caps_for(issuer)}
      _ = apply(Ezagent.Workspace, :add_member, [ws_name, user_uri, ctx])
    end

    :ok
  end

  defp founder_join(ws_name, %URI{} = user_uri) do
    if workspace_loaded?(:add_member, 2) do
      _ = apply(Ezagent.Workspace, :add_member, [ws_name, user_uri])
    end

    :ok
  end

  defp create_self_serve_workspace(ws_name, email) do
    cond do
      not workspace_loaded?(:create, 2) ->
        {:error, :workspace_unavailable}

      true ->
        case apply(Ezagent.Workspace, :create, [ws_name, %{}]) do
          {:ok, _} ->
            # A user_list rule with just this email so the founder is accepted.
            if workspace_loaded?(:add_magic_link_rule, 3) do
              key = ws_name |> Ezagent.URI.workspace() |> Ezagent.URI.stable_key()
              _ = apply(Ezagent.Workspace, :add_magic_link_rule, [key, "user_list", email])
            end

            :ok

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp workspace_loaded?(fun, arity) do
    Code.ensure_loaded?(Ezagent.Workspace) and function_exported?(Ezagent.Workspace, fun, arity)
  end

  defp random_suffix do
    :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
  end
end
