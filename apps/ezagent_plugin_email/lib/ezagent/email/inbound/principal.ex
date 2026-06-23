defmodule Ezagent.Email.Inbound.Principal do
  @moduledoc """
  Restricted synthetic participant identity for inbound email injection
  (#88 PR-2 / SPEC §4.6 / BLOCKER 2 part 3 / plan D5).

  Inbound email MUST NOT be injected under an arbitrary or admin caller.
  This mints a least-privilege EPHEMERAL identity to carry into the
  injection dispatch ctx:

  - **Principal URI** — a synthetic, workspace-scoped
    `entity://<workspace>/user/email-<short-id>` (a real `%URI{scheme:
    "entity"}`, Decision #154-compliant). It stands ONLY for the external
    email correspondent on this binding; it is NOT the admin URI and NOT
    any real ezagent user.

  - **Caps** — EXACTLY ONE cap: `session.send` scoped to that ONE bound
    session in its workspace. Nothing else (cannot bind, list, or reach
    any other session).

  ## Why an ephemeral ctx-cap (not a grant, not a Catalog principal)

  Per `capbac.md` §3, a dispatch authorizes when `ctx.caps` contains a cap
  matching the needed shape (path 1 `granted_via_ctx_caps?`) — the cap is
  never persisted and `granted_by` is not consulted on this path. So this
  mirrors `Ezagent.Behavior.Agent.Receive`'s self-authority carried inline
  at the dispatch (capbac §7): the cap goes straight into the injection
  `ctx.caps`, NOT through `Ezagent.Identity.Grant` (that chokepoint is for
  PERSISTED grant/revoke and is grep-gated to `:grant_cap`/`:revoke_cap`),
  and NOT via a new `system://` Catalog principal (those are persisted
  standing authority). `granted_by` is the synthetic participant itself
  (genuine self-authority, a real entity URI).

  The cap's `behavior` is the SINGLE behavior the dispatcher resolves for
  `Session :send` (via `BehaviorRegistry`), pinned for least-privilege.
  """

  require Logger

  @doc """
  Build `{principal_uri, caps}` for injecting one inbound email into
  `session_uri`. `caps` is a `MapSet` holding exactly the one `session.send`
  cap, scoped to this session.
  """
  @spec mint(URI.t()) :: {URI.t(), MapSet.t(Ezagent.Capability.t())}
  def mint(%URI{} = session_uri) do
    workspace_name = Ezagent.URI.workspace_name!(session_uri)
    principal_uri = Ezagent.URI.entity(workspace_name, :user, "email-" <> short_id())

    caps = MapSet.new([send_cap(session_uri, principal_uri)])
    {principal_uri, caps}
  end

  # The single narrow send cap. Concrete-URI instance (matches ONLY this
  # session's `session.send` need) + the dispatcher-resolved behavior for
  # `Session :send`. `granted_by` = the synthetic participant (self-authority,
  # a real entity — provenance-only; the step-5.5 authorizer is `ctx.caps`,
  # never routed through Grant).
  defp send_cap(%URI{} = session_uri, %URI{} = principal_uri) do
    %Ezagent.Capability{
      kind: :session,
      behavior: send_behavior(),
      action: :send,
      instance: Ezagent.URI.instance(session_uri),
      workspace_uri: Ezagent.Capability.workspace_of(session_uri),
      granted_by: principal_uri,
      granted_at: DateTime.utc_now()
    }
  end

  # The behavior module the dispatcher resolves for `Session :send` (so the
  # minted held-cap matches the `needed` shape step 5.5 derives). Falls back
  # to `Ezagent.Behavior.Session` if the registry isn't populated (the static
  # default — same module the registration declares).
  defp send_behavior do
    case Ezagent.BehaviorRegistry.lookup(Ezagent.Entity.Session, :send) do
      {:ok, behavior_module} -> behavior_module
      :error -> Ezagent.Behavior.Session
    end
  end

  defp short_id do
    :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)
  end
end
