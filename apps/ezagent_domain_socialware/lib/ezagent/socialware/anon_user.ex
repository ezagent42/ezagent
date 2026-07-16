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
      `granted_by:` the session owner (the configurer of the public_view rule —
      accountability only, never the caller), falling back to
      `entity://system/user/admin` for a not-yet-claimed ownerless session
      (Decision #154's named extreme-case granter; never a `system://` principal).
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
        born_with = [
          join_cap(session_uri) | Ezagent.Socialware.Installation.anon_view_caps(session_uri)
        ]

        with {:ok, issued} <- issue_born_with(born_with, anon_uri, session_uri),
             {:ok, _row} <- Users.create_read_only(anon_uri, issued) do
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
  # `granted_by` = the session owner (the configurer of the public_view rule);
  # for a not-yet-owner-claimed session it falls back to the admin entity —
  # Decision #154's named extreme-case granter — never a `system://` principal.
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
  defp issue_born_with(caps, %URI{} = anon_uri, %URI{} = _session_uri) do
    caps
    |> Enum.reduce_while({:ok, []}, fn cap, {:ok, acc} ->
      case Ezagent.Cap.issue(
             {:admin, Ezagent.URI.user(:system, :admin)},
             anon_uri,
             cap
           ) do
        {:ok, artifact} -> {:cont, {:ok, [artifact | acc]}}
        {:error, reason} -> {:halt, {:error, {:anon_cap_refused, reason}}}
      end
    end)
    |> case do
      {:ok, issued} -> {:ok, Enum.reverse(issued)}
      {:error, _} = error -> error
    end
  end

  defp join_cap(%URI{} = session_uri) do
    %Ezagent.Capability{
      kind: :session,
      behavior: Ezagent.ActionSet.Session,
      action: :join,
      instance: Ezagent.URI.instance(session_uri),
      workspace_uri: Ezagent.Capability.workspace_of(session_uri),
      granted_by: public_view_granter(session_uri),
      granted_at: DateTime.utc_now()
    }
  end

  defp public_view_granter(%URI{} = session_uri) do
    case Ezagent.Entity.Session.owner(session_uri) do
      {:ok, %URI{} = owner} -> owner
      _ -> Ezagent.Entity.User.admin_uri()
    end
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
