defmodule Ezagent.Socialware.AnonTakeover do
  @moduledoc """
  Anon→login takeover orchestrator (#154 spec 甲-5, route B).

  A CONFIRMED user takes over an anonymous user's session footprint, then the
  anon is retired. This is the socialware-domain chokepoint that ties together
  the cross-domain pieces a single domain cannot:

    1. **Consistency check (NOT the possession proof).**
       `AnonBinding.get(anon_uri)` must exist AND its `session_uri` must equal
       the target session, AND the session must STILL be public-view
       (`PublicView.public_view?/1` — a session can flip public→private at
       runtime via `set_working_copy`, so a stale binding must not let a
       cap-less `do_join` land a confirmed user in a now-private session).
       Fail-closed (`:no_anon_binding` / `:session_mismatch` / `:not_public_view`).
    2. **Assert the caller is confirmed.** `Users.confirmed?(confirmed_user_uri)`
       — fail-closed otherwise. An anonymous user cannot take over another anon.
    3. **Dispatch the session `:takeover` action** (footprint transfer:
       confirmed-user join + anon membership removal + ReadMarker re-point). The
       session domain stays socialware-symbol-free; it receives `anon` + `member`
       as plain `%URI{}`.
    4. **On `:ok`, mount the confirmed tier** caller-side
       (`Membership.mount_participation_caps/2` — its `:sync` grant calls
       `Session.owner` and so MUST run here, not inside the Session Kind).
    5. **Retire the anon** — `Users.delete/1` (tears down the Kind snapshot +
       provisioning row) + `AnonBinding.delete/1` (the §4.4 login-replacement
       reap). STRICTLY after a successful transfer, so a half-transfer never
       leaves the anon orphaned.

  ## CALLER CONTRACT (HARD REQUIREMENT — the possession proof lives HERE'S CALLER)

  **`takeover/3` does NOT prove the caller possesses `anon_uri`.** Anon URIs are
  observable (anon users appear in session member lists), and BOTH `anon_uri`
  and `session_uri` are caller-supplied, so step-1's `AnonBinding` lookup is a
  CONSISTENCY check, never a possession proof. The cryptographic possession
  proof is the signed `socialware_anon` cookie, verified by
  `EzagentWeb.Socialware.AnonCookie.verify/2` — which lives in the WEB layer
  (`ezagent_web`), because verifying it needs the endpoint secret, and
  `ezagent_domain_socialware` must not depend on `ezagent_web`.

  Therefore the SOLE sanctioned caller is the spec-乙 web controller, which MUST:
  (a) `AnonCookie.verify/2` the request's anon cookie → derive the TRUSTED
  `anon_uri` + `session_uri` (NEVER from a request param / the member list),
  (b) authenticate the confirmed user, (c) call `takeover/3` with those verified
  values. Calling `takeover/3` with an unverified, caller-chosen `anon_uri` is a
  hijack vector — the function trusts its caller to have done (a). Until that
  controller lands (spec 乙), this module has NO production caller and is inert.

  ## The authorization model (#154 — no new principal / cap axis)

  Beyond the caller's cookie verify, the `:takeover` dispatch is authorized by an
  INLINE `cap(:session, Behavior.Session, :takeover, <session>)` `granted_by:`
  the confirmed member (self-claim, provenance-only — the same inline-authorizer
  pattern the agent reply bridges use; never routed through `Identity.Grant`,
  never persisted). No entity is ever GRANTED a `:takeover` cap, so the action is
  reachable ONLY by code that mints this inline cap — i.e. this orchestrator —
  never by an external `/api/v1` caller (whose `ctx.caps` come from authenticated
  HELD caps, not arbitrary inline caps).

  `provision_join_authority/2` is deliberately NOT used: the session is an OWNED
  public-view session, so that owner-rooted policy would deny a non-owner /
  non-member confirmed user. `do_takeover` calls `do_join` DIRECTLY (a function
  call, not a re-dispatch of `session.join`), so no `:join` cap is consulted —
  safe because the step-1 `public_view?` re-check confines takeover to
  open-join public sessions the confirmed user could have joined anyway.

  ## Cross-domain seam (Task 1 decision)

  `ezagent_domain_socialware` depends on `ezagent_domain_session` (verified in
  the mix.exs files), NOT the reverse. So the orchestration + the anon retire
  (which reference socialware symbols `AnonBinding`/`Users`) live HERE; the
  session-domain `:takeover` action + `Membership.do_takeover/4` reference NO
  socialware symbol (the `undeclared_umbrella_dep_test` / acyclic invariant).

  Idempotent: a second `takeover/3` after the first retired the binding returns
  `{:error, :no_anon_binding}` (already taken over).
  """

  alias Ezagent.Behavior.Session.Membership
  alias Ezagent.Socialware.AnonBinding
  alias Ezagent.Socialware.PublicView
  alias Ezagent.Users

  @doc """
  Take over `anon_uri`'s footprint in `session_uri` on behalf of the confirmed
  `confirmed_user_uri`, then retire the anon. See the module doc for the full
  flow + authority model.

  Returns `{:ok, %{members: [URI.t()]}}` (the session's members after the
  transfer) or `{:error, term()}` (fail-closed on any gate). Common errors:
  `:no_anon_binding`, `:session_mismatch`, `:not_confirmed`.
  """
  @spec takeover(URI.t(), URI.t(), URI.t()) ::
          {:ok, %{members: [URI.t()]}} | {:error, term()}
  def takeover(%URI{} = anon_uri, %URI{} = confirmed_user_uri, %URI{} = session_uri) do
    with :ok <- validate_binding(anon_uri, session_uri),
         :ok <- validate_public_view(session_uri),
         :ok <- validate_confirmed(confirmed_user_uri),
         {:ok, result} <- dispatch_takeover(anon_uri, confirmed_user_uri, session_uri) do
      # Footprint transfer succeeded — now mount the confirmed tier caller-side
      # (its :sync grant calls Session.owner, must NOT run in the Session Kind),
      # then retire the anon (strictly after success — never orphan a transfer).
      :ok = Membership.mount_participation_caps(session_uri, confirmed_user_uri)
      retire_anon(anon_uri)
      {:ok, result}
    end
  end

  def takeover(_, _, _), do: {:error, :invalid_args}

  # ----- gates ---------------------------------------------------------------

  defp validate_binding(%URI{} = anon_uri, %URI{} = session_uri) do
    case AnonBinding.get(anon_uri) do
      nil ->
        {:error, :no_anon_binding}

      %AnonBinding{session_uri: bound_session} ->
        if bound_session == URI.to_string(session_uri) do
          :ok
        else
          {:error, :session_mismatch}
        end
    end
  end

  # A session can flip public→private at runtime (`set_working_copy` repoints the
  # working copy). A stale `AnonBinding` must NOT let the cap-less `do_join` land
  # a confirmed user in a now-private session — re-check public-view at takeover
  # time, not just at anon-mint time.
  defp validate_public_view(%URI{} = session_uri) do
    if PublicView.public_view?(session_uri), do: :ok, else: {:error, :not_public_view}
  end

  defp validate_confirmed(%URI{} = confirmed_user_uri) do
    if Users.confirmed?(confirmed_user_uri), do: :ok, else: {:error, :not_confirmed}
  end

  # ----- dispatch ------------------------------------------------------------

  defp dispatch_takeover(%URI{} = anon_uri, %URI{} = confirmed_user_uri, %URI{} = session_uri) do
    target = Ezagent.URI.with_action(session_uri, :session, :takeover)

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: target,
      mode: :call,
      args: %{anon: anon_uri, member: confirmed_user_uri},
      ctx: %{
        caller: confirmed_user_uri,
        caps: [inline_takeover_cap(session_uri, confirmed_user_uri)],
        reply: :ignore
      }
    })
  end

  # The confirmed user's OWN inline `:takeover` cap (self-claim) — the step-5.5
  # authorizer for the `session.takeover` action. `granted_by` = the confirmed
  # user (genuine self-authority, #154-ok); inline ⇒ provenance-only, never
  # routed through Grant, never persisted. The needed-cap dispatch derives for
  # `session.takeover` is `cap(:session, Behavior.Session, :takeover, <session>)`,
  # so the inline cap pins those exact axes.
  defp inline_takeover_cap(%URI{} = session_uri, %URI{} = member_uri) do
    %Ezagent.Capability{
      Ezagent.Capability.cap(
        :session,
        Ezagent.Behavior.Session,
        :takeover,
        Ezagent.URI.instance(session_uri),
        Ezagent.Capability.workspace_of(session_uri)
      )
      | granted_by: member_uri,
        granted_at: DateTime.utc_now()
    }
  end

  # ----- retire --------------------------------------------------------------

  # §4.4 login-replacement reap — tear down the anon Kind/row, THEN drop the
  # binding (binding LAST so a crash mid-retire re-surfaces a recoverable row).
  defp retire_anon(%URI{} = anon_uri) do
    :ok = Users.delete(anon_uri)
    _ = AnonBinding.delete(anon_uri)
    :ok
  end
end
