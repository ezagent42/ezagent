defmodule Ezagent.Socialware.AnonUser do
  @moduledoc """
  The ephemeral **anonymous external user** for socialware membership-only access
  (issue #51).

  An anon-User is a flavor of the `Ezagent.Entity.User` Kind — a real bare
  principal `entity://<viewed-workspace>/user/anon-<random>` — minted **read-only
  by construction** so it may VIEW a single socialware session it is a member of,
  but cannot WRITE.

  ## Why a User flavor (not a new Kind)

  `Ezagent.Session.Membership.valid_caller_uri?` delegates to
  `Ezagent.URI.bare_principal?/1`, which accepts only
  `entity://<ws>/<user|agent|worker>/<name>`. To keep the access model
  **membership-only** (no new "non-member can read" permission), the viewer must be
  one of those three entity types, and `user` is the honest fit for a human
  visitor. The User Kind lazily demand-spawns via the `entity://` SpawnRegistry fn
  and hydrates caps from `users.caps_json` via
  `Ezagent.Entity.User.initial_caps_for_spawn/1` — so a row with an EMPTY caps_json
  demand-spawns with no session cap.

  ## Read-only by CONSTRUCTION

  `mint/1` creates the `users` row via `Ezagent.Users.create_read_only/1`, which
  does NOT prepend `Ezagent.Entity.User.default_caps/1` (the broad session baseline
  cap normal users get). The anon-User therefore holds only the structural
  self-Identity cap: it READS via session membership but a `chat.send` is denied at
  the CapBAC chokepoint (dispatch step 5.5) for want of a session write cap.

  ## Workspace scoping

  The minted URI carries the **viewed session's workspace** segment, so the
  anon-User can never be used cross-workspace (every workspace scope is derived
  from the entity's own URI; a leaked cap would be blocked by
  `Ezagent.Capability.cross_workspace?/2`).

  ## Lifecycle

  Minted on the first anonymous open of a `public_view` socialware page, joined to
  the session (`Behavior.Session` `:join`), and GC'd 48h after `last_seen_at` by an
  in-app sweeper. The cookie→entity binding table + the sweeper are the deferred
  web-layer/persistence surface (see the spec §3.4 + the `:pending_impl` tests);
  this module owns the URI minting + the read-only row + the predicates.
  """

  require Logger

  alias Ezagent.Users

  @anon_prefix "anon-"
  @random_bytes 16

  @doc """
  Mint a fresh read-only anon-User bound to `session_uri`'s workspace.

  Returns `{:ok, anon_user_uri}` — a canonical
  `entity://<viewed-workspace>/user/anon-<random>` `%URI{}` whose backing `users`
  row has an EMPTY caps_json (read-only by construction). `<random>` is a 128-bit
  URL-safe token, so the name is unguessable and collision-free.

  The workspace segment is derived from `session_uri` via
  `Ezagent.Capability.workspace_of/1`, so the anon-User lives in the SAME workspace
  as the session it will view.
  """
  @spec mint(URI.t()) :: {:ok, URI.t()} | {:error, term()}
  def mint(%URI{scheme: "session"} = session_uri) do
    case Ezagent.URI.workspace_name(session_uri) do
      {:ok, workspace_name} ->
        anon_uri = Ezagent.URI.entity(workspace_name, :user, anon_name())

        case Users.create_read_only(anon_uri) do
          {:ok, _row} -> {:ok, anon_uri}
          {:error, _} = err -> err
        end

      :error ->
        {:error, {:no_workspace, session_uri}}
    end
  end

  def mint(other), do: {:error, {:not_a_session, other}}

  @doc """
  Mint a read-only anon-User **authorized to participate in a `public_view`
  session** — the issue #51 §4.1 anonymous-access chokepoint (GLOSSARY
  Decision #154, no unowned permissions).

  This is the structural-authorization branch: `public_view == true` is ITSELF
  the rule that authorizes minting the anon a NARROW participation grant. The
  authority is NOT routed through `Behavior.IdentityAdmin.grant_cap`'s
  `{self, admin, manager}` chokepoint (the anonymous HTTP path is none of those
  — all three branches fail closed), and NO `system://` principal is involved.
  Instead the grant is born WITH the identity, written into the anon's
  `caps_json` at create time (the same create-time mechanism `default_caps/1`
  uses), so the anon hydrates the cap on demand-spawn and joins ONLY its own
  session under its OWN authority.

  Returns:

    * `{:ok, anon_uri}` — `session_uri` is a live `public_view` session; a fresh
      read-only anon-User is created holding EXACTLY one cap:
      `cap(:session, Behavior.Session, :join, instance: <session>, ws: <session ws>)`,
      `granted_by:` the canonical admin entity that actually exercises the
      target Kind's sealed authority (never an impersonated owner and never a
      `system://` principal).
    * `{:error, :not_public_view}` — `session_uri` is private (or its public-view
      flag cannot be resolved). The rule branch checks the flag is ACTUALLY true;
      a private session NEVER mints an anon-access identity.
    * `{:error, term()}` — workspace/owner/row-creation failure.

  The minted cap's `instance` is the CONCRETE session URI (`Ezagent.URI.instance/1`
  — exactly the needed-instance dispatch derives for a `session.join` on this
  session), strictly tighter than a `{:within_session, _}` scope tuple: it
  authorizes this session ONLY (not its sub-resources, never another session) and
  is JSON-serializable for `caps_json` (a scope tuple is not — see
  `Ezagent.Capability.Normalize.to_map/1`).
  """
  @spec mint_for_public_session(URI.t()) :: {:ok, URI.t()} | {:error, term()}
  def mint_for_public_session(%URI{scheme: "session"} = session_uri) do
    if Ezagent.Socialware.PublicView.web_anon_access?(session_uri) do
      with {:ok, workspace_name} <- workspace_name(session_uri) do
        anon_uri = Ezagent.URI.entity(workspace_name, :user, anon_name())

        # T2-2b — born with the narrow session.join grant PLUS the view read-caps
        # for PUBLIC installed definitions' declared views only
        # (`Installation.anon_view_caps/1`). A view of a non-public installed
        # definition contributes no cap → the anon cannot render it
        # (`SessionView.authorize_view/3` denies). Two-layer gate: openness admits
        # the anon; view-caps decide which views it sees.
        # Two granters, deliberately: the session-participation caps are
        # RULE-DRIVEN issuance the platform authorizes (granter = the canonical
        # admin, the only accountable system principal), while an A5 share's read
        # key is the OWNER's grant over the OWNER's resource — so the owner signs
        # for it (`granted_by` = the share's `granter_uri`, matching #154's
        # "granter ≡ data_owner").
        rule_caps =
          [join_cap(session_uri) | Ezagent.Socialware.Installation.anon_view_caps(session_uri)]

        with {:ok, issued_rule} <-
               issue_born_with(rule_caps, anon_uri, {:admin, Ezagent.URI.user(:system, :admin)}),
             {:ok, issued_share} <- issue_share_read_caps(session_uri, anon_uri),
             {:ok, _row} <- Users.create_read_only(anon_uri, issued_rule ++ issued_share) do
          {:ok, anon_uri}
        end
      end
    else
      {:error, :not_public_view}
    end
  end

  def mint_for_public_session(other), do: {:error, {:not_a_session, other}}

  # The single narrow participation grant the anon is born with. Concrete-URI
  # instance (NOT a `{:within_session, _}` tuple — see the @doc) so it matches
  # ONLY this session's `session.join` need + serializes into caps_json.
  # `granted_by` = the canonical admin entity that actually authorizes this
  # rule-driven issuance through the target Kind's sealed authority. Recording
  # an arbitrary session owner here would be issuer impersonation.
  # Decision #162 (ISSUE → STORE → VERIFY): `Users.create_read_only/2` writes
  # straight into `users.caps_json`, and `Behavior.Identity.post_init/2`
  # reconciles the user Kind's cap slice FROM that column — so anything put
  # there IS authority granted. These caps used to go in without ever passing
  # `Ezagent.Cap.issue/3`, i.e. without `authorize_grant/3` ever running.
  #
  # Unlike `create_user` (the arbitrary-cap oracle fixed in this PR), nothing
  # here is caller-supplied: both shapes are code-constructed and narrow. The
  # exposure was therefore latent, not live. But an ungated write path is one
  # `Installation.anon_view_caps/1` change away from handing an ANONYMOUS,
  # unauthenticated visitor an unbounded capability — and nothing would have
  # stopped it.
  #
  # `{:rule, :anon_public_view_mint, granter}` is the right authorization: there
  # is no human granting anything here, it is a system rule, and the rule branch
  # of `authorize_grant/3` enforces `rule_cap_bounded?/1` — a concrete instance
  # AND a concrete action. So an anon can no longer be BORN with a wildcard,
  # structurally, whatever a future definition declares.
  # `authorization` is passed IN, never inferred by comparing the granter to a
  # fixed principal — each call site already knows which kind of grant it is
  # (rule-driven platform issuance vs the owner's grant over its own resource),
  # and inferring it by comparing the granter against a fixed principal is
  # exactly the hardcoded admin-principal shape that #154 locked out.
  defp issue_born_with(caps, %URI{} = anon_uri, authorization) do
    caps
    |> Enum.reduce_while({:ok, []}, fn cap, {:ok, acc} ->
      case Ezagent.Cap.issue(authorization, anon_uri, cap) do
        {:ok, artifact} -> {:cont, {:ok, [artifact | acc]}}
        {:error, reason} -> {:halt, {:error, {:anon_cap_refused, reason}}}
      end
    end)
    |> case do
      {:ok, issued} -> {:ok, Enum.reverse(issued)}
      {:error, _} = error -> error
    end
  end

  # The share read key is issued BY THE SHARE'S OWNER — `AnonShare.enable/4` made
  # sure the owner holds grant authority over its own target first, so
  # `{:held_by, owner}` is a real, verifiable grant rather than a system-principal
  # rubber stamp. No share bound to this session ⇒ nothing to issue.
  defp issue_share_read_caps(%URI{} = session_uri, %URI{} = anon_uri) do
    case anon_share_grant(session_uri) do
      nil -> {:ok, []}
      {owner, caps} -> issue_born_with(caps, anon_uri, {:held_by, owner})
    end
  end

  # A5 (`link_anon`) — if this public session is an anon share's DEDICATED
  # session (`ShareSetting.by_anon_session/1`, ENABLED rows only), the anon is
  # additionally born with the share's declared read key(s) toward the target.
  #
  # Per-anon born-with is the ESTABLISHED anon pattern (exactly how the view
  # read-caps above work) — and the empirically forced one: the dedicated
  # session cannot hold the key itself, because the Session Kind mounts no
  # Identity storage actions (`identity.absorb_cap` → `{:unknown_action, _}`;
  # `entity/session.ex` `behaviors/0` carries `SelfLicense` only). The share
  # ROW stays the policy switch: owner disables → this stops contributing for
  # every NEW anon at once, and the projection (row-gated) goes dark for
  # existing ones; already-born keys are untouched — the exact `link_login`
  # revocation semantics (codex D3: flip kills the link, revoke per-person
  # separately), with target authority rotation as the hard lever.
  #
  # Bounded like every born-with: concrete action × concrete target instance
  # (`rule_cap_bounded?` shape) — an anon can never be born with a wildcard.
  # Returns `{owner, [cap_request]}` — the OWNER is carried out so the caller can
  # issue under the owner's own grant authority (#154: granter ≡ data_owner).
  defp anon_share_grant(%URI{} = session_uri) do
    case Ezagent.Socialware.ShareSetting.by_anon_session(session_uri) do
      nil ->
        nil

      # The read-only TIER is enforced HERE, at the mint site — not left to the
      # `access: :read` that `AnonShare.enable/4` happens to pass. A row at any
      # other tier mints nothing, so a future caller that widens the tier leaves
      # the anon powerless instead of silently write-capable.
      %{access: access} when access != "read" ->
        nil

      setting ->
        target = Ezagent.URI.new!(setting.target_uri)
        owner = Ezagent.URI.new!(setting.granter_uri)
        behavior = Ezagent.Socialware.ShareSetting.behavior_module(setting)

        # Built via `Capability.cap/5` (the sanctioned request constructor), NOT a
        # provenance-bearing struct literal: real provenance is stamped by
        # `Cap.issue`'s `prepare_provenance` — a struct field set here would be
        # overwritten anyway (empirically pinned by the A2-2 grantee-index tests).
        caps =
          for action <- Ezagent.Socialware.ShareSetting.actions(setting) do
            Ezagent.Capability.cap(
              :agent,
              behavior,
              action,
              Ezagent.URI.instance(target),
              Ezagent.Capability.workspace_of(target)
            )
          end

        {owner, caps}
    end
  rescue
    error ->
      # "Who finds out if this fails?" — a bad target_uri, an actions_json atom
      # that is not loaded, … would otherwise leave the visitor silently keyless
      # and the page silently empty. Still fail-closed, but no longer silent.
      Logger.warning(
        "AnonUser.anon_share_grant: minting skipped for " <>
          "#{URI.to_string(session_uri)} (#{inspect(error)}) — visitor gets no read key"
      )

      nil
  end

  defp join_cap(%URI{} = session_uri) do
    %Ezagent.Capability{
      kind: :session,
      behavior: Ezagent.ActionSet.Session,
      action: :join,
      instance: Ezagent.URI.instance(session_uri),
      workspace_uri: Ezagent.Capability.workspace_of(session_uri),
      granted_by: Ezagent.Entity.User.admin_uri(),
      granted_at: DateTime.utc_now()
    }
  end

  defp workspace_name(%URI{} = session_uri) do
    case Ezagent.URI.workspace_name(session_uri) do
      {:ok, _name} = ok -> ok
      :error -> {:error, {:no_workspace, session_uri}}
    end
  end

  @doc """
  Whether `uri` is an anon-User URI — a bare `user` principal whose name carries
  the `anon-` prefix. Used by GC + "hide anonymous viewers" filters.
  """
  @spec anon_uri?(term()) :: boolean()
  def anon_uri?(%URI{scheme: "entity"} = uri) do
    with true <- Ezagent.URI.bare_principal?(uri),
         true <- Ezagent.URI.type?(uri, :user),
         {:ok, name} <- Ezagent.URI.name(uri) do
      String.starts_with?(name, @anon_prefix)
    else
      _ -> false
    end
  end

  def anon_uri?(_), do: false

  @doc "The `anon-` name prefix every anon-User carries."
  @spec prefix() :: String.t()
  def prefix, do: @anon_prefix

  defp anon_name do
    @anon_prefix <>
      (:crypto.strong_rand_bytes(@random_bytes) |> Base.url_encode64(padding: false))
  end
end
