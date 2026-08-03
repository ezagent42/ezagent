defmodule Ezagent.Socialware.AnonShare do
  @moduledoc """
  A5 — anonymous sharing (`link_anon`): the ORCHESTRATION behind the most-open
  rung of the share ladder.

  ## The shape (approved by Allen on #1594, 2026-07-29)

  > 每个被匿名分享的资源 = 专属公开 session(仅 mount 该资源 + `web_anon_access`,
  > 链接指向它),天然隔离。

  So `enable/4` provisions a **dedicated public session per shared target**:

      <target's workspace> / <stock template> / r-<stable-key-of-target>

  One shared thing per session is what makes the anon page **structurally**
  isolated — a visitor who lands on one share cannot reach another, because
  there is nothing else in that session to reach. (`ShareSetting`'s unique
  partial index on `anon_session_uri` enforces the 1:1 at the storage layer.)

  ## Division of labour

    * `Ezagent.Socialware.ShareSetting` — persistence only. It refuses a
      `link_anon` row without an `:anon_session_uri`, so a half-working state
      (visibility promises anonymous access, visitor has nowhere to land) is
      unrepresentable.
    * **this module** — provisioning: seed the public definition/template, create
      the session, mint the read cap, then hand the result to `ShareSetting`.
    * `Ezagent.Socialware.ExternalFeed` — the read path, which asks
      `ShareSetting.by_anon_session/1` what this public session is showing.

  ## Who holds the key (design open-question 4, resolved EMPIRICALLY)

  The read key toward the target is born-with-minted to **each admitted
  anonymous visitor** (`AnonUser.anon_share_read_caps/1`), NOT to the dedicated
  session:

    * the session-as-holder variant was implemented first and REFUTED by the
      substrate: the Session Kind mounts no Identity storage actions, so the
      minted key's absorb dispatch dies with
      `{:unknown_action, :absorb_cap}` — a session cannot hold identity-plane
      caps today (`entity/session.ex` `behaviors/0` = `SelfLicense` only).
    * per-anon born-with is the ESTABLISHED anon pattern — it is exactly how
      the view read-caps work (`Installation.anon_view_caps/1`), bounded to
      concrete action × concrete instance.
    * the projection dispatch then runs AS THE REAL VISITOR (true provenance),
      through the full cap chokepoint.

  Revocation is two-layer, mirroring `link_login` (codex D3): the share ROW is
  the policy switch — `disable/2` flips it and the row-gated projection goes
  dark for everyone at once — while already-born keys are untouched and die at
  target authority rotation (`Cap.Authority.regenesis`) or anon GC.
  """

  require Logger

  alias Ezagent.Socialware.{DefinitionRegistry, Installation, Share, ShareSetting}

  # The dedicated session is created from the STOCK `default` template and then
  # has the public definition installed into it explicitly. Determinism (and thus
  # idempotence) comes from the per-target short name below, not from a bespoke
  # template — one less seeded object to keep alive, and it matches how sessions
  # are provisioned everywhere else.
  @template_name "default"

  # The socialware definition whose `visibility_policy.web_anon_access` is what
  # actually makes the provisioned session anonymously readable
  # (`Installation.web_anon_access?/1` = "any installed definition declares it").
  @definition_name "anon-share-view"

  @doc """
  Turn ON anonymous sharing for `target`.

  Idempotent: re-enabling an already-shared target reuses the same dedicated
  session (same deterministic URI) and re-upserts the share row.

  Returns `{:ok, %{session: URI.t(), setting: ShareSetting.t()}}`. Every failure
  is fail-closed: on any step failing, no share row is written, so `link_anon` is
  never left half-provisioned.
  """
  @spec enable(URI.t(), URI.t(), module(), [atom()]) ::
          {:ok, %{session: URI.t(), setting: ShareSetting.t()}} | {:error, term()}
  def enable(%URI{} = target, %URI{} = owner, behavior, actions)
      when is_atom(behavior) and is_list(actions) and actions != [] do
    workspace_uri = Ezagent.Capability.workspace_of(target)

    # Owner is verified HERE, before anything is provisioned — otherwise a
    # non-owner could make us create sessions. The write path verifies it again
    # (it is the authority for every later claim); this is the cheap up-front
    # guard, not a replacement for that one.
    #
    # The row is written through the A1 facade `Share.enable/5`, NOT straight to
    # `ShareSetting` — the facade carries the M2 conformance check (the target
    # really does handle this behavior × these actions), and an anon share has no
    # business skipping it.
    with :ok <- assert_owner(target, behavior, owner),
         :ok <- ensure_owner_grant_authority(target, owner),
         :ok <- ensure_public_definition(workspace_uri),
         {:ok, session_uri} <- ensure_session(target, owner, workspace_uri),
         {:ok, setting} <-
           Share.enable(target, owner, behavior, actions,
             visibility: :link_anon,
             access: :read,
             anon_session_uri: session_uri
           ) do
      {:ok, %{session: session_uri, setting: setting}}
    end
  end

  @doc """
  Turn OFF anonymous sharing for `target`.

  Flips the share row off — `by_anon_session/1` returns ENABLED rows only, so
  the row-gated projection goes dark for every visitor at once, and admission
  stops minting the read key to new anons. Already-born keys are deliberately
  untouched (the `link_login` revocation semantics, codex D3: the flip kills the
  link; revoke per-person separately; target authority rotation is the hard
  lever). The session itself is left in place: re-enabling reuses it, and an
  empty public session exposes nothing.
  """
  @spec disable(URI.t(), URI.t()) :: :ok | {:error, term()}
  def disable(%URI{} = target, %URI{} = owner) do
    with {:ok, _} <- ShareSetting.disable(target, owner) do
      :ok
    end
  end

  @doc "The dedicated public session URI for `target` (deterministic, no I/O)."
  @spec session_uri_for(URI.t()) :: URI.t()
  defdelegate session_uri_for(target), to: ShareSetting, as: :anon_session_uri_for

  # ── steps ────────────────────────────────────────────────────────────────

  defp assert_owner(target, behavior, owner) do
    case Ezagent.CapabilityRegistry.data_owner_of(behavior, Ezagent.URI.instance(target)) do
      %URI{} = current ->
        if Ezagent.URI.stable_key(current) == Ezagent.URI.stable_key(owner),
          do: :ok,
          else: {:error, {:anon_share_not_target_owner, owner, current}}

      _ ->
        {:error, {:anon_share_target_ownerless, target}}
    end
  end

  # The owner must be able to SIGN the read keys handed to visitors — those are
  # the owner's grant over the owner's own resource (#154: granter ≡ data_owner),
  # not a system-principal rubber stamp. This is the production path that gives an
  # owner grant authority over its target (admin-authorized, target-signed); it is
  # idempotent, and doing it HERE means admission never has to mint authority on
  # the fly for a visitor that is already at the door.
  defp ensure_owner_grant_authority(target, owner) do
    case Ezagent.Identity.TargetAuthority.ensure(owner, Ezagent.URI.instance(target)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:anon_share_owner_authority_failed, reason}}
    end
  end

  # Seed (idempotently) the definition that carries `web_anon_access: true`, plus
  # the template that installs it. Both are seed-if-absent, so concurrent enables
  # and repeat enables converge on the same objects.
  defp ensure_public_definition(workspace_uri) do
    definition = %{
      name: @definition_name,
      bases: [Ezagent.ActionSet.Session, Ezagent.ActionSet.Publisher.SessionImpl],
      shape: [Ezagent.ActionSet.Turn, Ezagent.ActionSet.Surface],
      owner_policy: %{type: :installer},
      # THIS is what makes the provisioned session anonymously readable.
      visibility_policy: %{publish_policy: :auto, web_anon_access: true}
    }

    case DefinitionRegistry.seed_definition_if_absent(definition, workspace_uri: workspace_uri) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:anon_share_definition_seed_failed, reason}}
    end
  end

  defp ensure_session(target, owner, workspace_uri) do
    uri = session_uri_for(target)

    # No "does it already exist" probe: `SessionCreator.create_session/3` is
    # idempotent under a per-URI lock (it verifies-or-recreates an existing
    # session), so the live check is a cheap fast path and the creator is the
    # authority. An earlier hand-rolled probe here was DEAD CODE — it pattern
    # matched a map against `installed_definitions/1`, which returns a list.
    if Ezagent.Kind.alive?(uri) do
      {:ok, uri}
    else
      create_session(target, owner, workspace_uri, uri)
    end
  end

  defp create_session(target, owner, workspace_uri, expected_uri) do
    # The short name is read back off the derived URI, so provisioning and the
    # row invariant can never drift apart — `ShareSetting` owns the derivation.
    short_name = expected_uri |> Ezagent.URI.instance() |> URI.to_string() |> Path.basename()

    with {:ok, session_uri, _meta} <-
           EzagentDomainInstanceMessage.SessionCreator.create_session(
             short_name,
             owner,
             workspace_uri: workspace_uri,
             template_name: @template_name
           ),
         :ok <- install_public_definition(session_uri, workspace_uri, owner) do
      {:ok, session_uri}
    else
      {:error, reason} ->
        Logger.warning(
          "AnonShare.enable: could not provision the dedicated public session " <>
            "#{URI.to_string(expected_uri)} for #{URI.to_string(target)}: #{inspect(reason)}"
        )

        {:error, {:anon_share_session_provision_failed, reason}}
    end
  end

  # Install the `web_anon_access: true` definition INTO the freshly created
  # session. This is the step that actually makes it anonymously readable —
  # `Installation.web_anon_access?/1` asks "does any INSTALLED definition declare
  # it", so seeding the definition alone is not enough.
  defp install_public_definition(session_uri, workspace_uri, owner) do
    content = %{installs: [@definition_name]}

    case Installation.install_template_installs(session_uri, workspace_uri, content, owner) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:anon_share_install_failed, reason}}
    end
  end

  # ── naming ───────────────────────────────────────────────────────────────

  # Deterministic per-target short name ⇒ deterministic session URI ⇒ idempotent
  # provisioning. Hashed because a target's own name can contain characters the
  # URI segment does not allow, and because the share link should not leak the
  # internal resource name.
end
