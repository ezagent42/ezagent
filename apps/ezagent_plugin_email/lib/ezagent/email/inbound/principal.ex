defmodule Ezagent.Email.Inbound.Principal do
  @moduledoc """
  Restricted synthetic participant identity for inbound email injection
  (#88 PR-2 / SPEC §4.6 / BLOCKER 2 part 3 / plan D5).

  Inbound email MUST NOT be injected under an arbitrary or admin caller.
  This derives a least-privilege EPHEMERAL identity to carry into the
  injection dispatch ctx:

  - **Principal URI** — a synthetic, workspace-scoped
    `entity://<workspace>/user/email-<short-id>` (a real `%URI{scheme:
    "entity"}`, Decision #154-compliant). It stands ONLY for the external
    email correspondent on this binding; it is NOT the admin URI and NOT
    any real ezagent user.

  - **Caps** — EXACTLY ONE cap: `session.send` scoped to that ONE bound
    session in its workspace. Nothing else (cannot bind, list, or reach
    any other session).

  ## Why a receiver-bound issued ctx-cap

  A verified inbound binding is a narrow authorization rule configured by an
  authenticated binding actor. `Ezagent.Cap.issue/3` records that actor as
  provenance, binds the signature to the synthetic receiver, and returns an
  artifact used only in this dispatch's `ctx.caps`. It is never persisted and
  creates no Catalog principal or third authority category.

  The cap's `behavior` is the SINGLE behavior the dispatcher resolves for
  `Session :send` (via `BehaviorRegistry`), pinned for least-privilege.
  """

  require Logger

  @doc """
  Build `{:ok, {principal_uri, caps}}` for injecting one inbound email into
  `session_uri`. `caps` is a `MapSet` holding exactly the one `session.send`
  cap, scoped to this session.
  """
  @spec mint(URI.t(), URI.t()) ::
          {:ok, {URI.t(), MapSet.t(Ezagent.Capability.t())}} | {:error, term()}
  def mint(%URI{} = session_uri, %URI{} = binding_actor) do
    workspace_name = Ezagent.URI.workspace_name!(session_uri)
    principal_uri = Ezagent.URI.entity(workspace_name, :user, "email-" <> short_id())

    case Ezagent.Cap.issue(
           {:rule, :verified_email_binding, binding_actor},
           principal_uri,
           send_cap(session_uri)
         ) do
      {:ok, cap} -> {:ok, {principal_uri, MapSet.new([cap])}}
      {:error, _reason} = error -> error
    end
  end

  # The single narrow send cap. Concrete-URI instance (matches ONLY this
  # session's `session.send` need) + the dispatcher-resolved behavior for
  # `Session :send`. Provenance and receiver binding are stamped only by Cap.issue/3.
  defp send_cap(%URI{} = session_uri) do
    Ezagent.Capability.cap(
      :session,
      send_behavior(),
      :send,
      Ezagent.URI.instance(session_uri),
      Ezagent.Capability.workspace_of(session_uri)
    )
  end

  # The behavior module the dispatcher resolves for `Session :send` (so the
  # minted held-cap matches the `needed` shape step 5.5 derives). Falls back
  # to `Ezagent.ActionSet.Session` if the registry isn't populated (the static
  # default — same module the registration declares).
  defp send_behavior do
    case Ezagent.BehaviorRegistry.lookup(Ezagent.Entity.Session, :send) do
      {:ok, behavior_module} -> behavior_module
      :error -> Ezagent.ActionSet.Session
    end
  end

  defp short_id do
    :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)
  end
end
