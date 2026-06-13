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
