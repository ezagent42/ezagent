defmodule Ezagent.Domain.Pty.Access do
  @moduledoc """
  Who may reach an agent's PTY. **The single home for the policy.**

  A PTY's OUTPUT is at least as sensitive as its input — `claude /login`
  authorization codes, secrets echoed by commands, source, the agent's whole
  conversation. Writing was CapBAC-gated all along (`Ezagent.ActionSet.Pty`
  dispatch → step 5.5). **Reading was not gated at all**: every read exit took
  the agent URI from client input and served the live output + scrollback to any
  authenticated entity, for any agent, across workspaces.

  Allen, 2026-07-14 — **the terminal belongs to the creator**. The creator's
  authority over an agent is the Manage cap they already receive at creation
  (`CreatorGrant.manage_cap/4`; #533 §3.3 — "any management action on THIS
  instance"), and `Ezagent.ActionSet.Pty` gates `:write` / `:restart` on exactly
  that cap. Reads are gated on it too, so ONE authority covers the whole
  terminal:

    * the agent's **creator** holds `cap(:agent, Manage, :any, <that agent>)` —
      already, for every agent that exists. No new grant, no backfill.
    * **admin**'s genesis wildcard matches everything.
    * **nobody else** — `behavior` and `instance` are both exact, so a Manage cap
      on someone else's agent does not open this one, and the workspace axis
      closes itself as a consequence rather than as a special case.

  This is what makes Allen's 2026-07-10 decision safe: "a user may deliberately
  create a credential-less cc agent and run `claude /login` inside its PTY" only
  holds if nobody else is watching that PTY while they type the code.

  ## Why the policy lives HERE and not in the caller

  There is **more than one read exit**, in more than one app:

    * `Ezagent.World.IdentityData` — the `/identities/agents/:uri/terminal` state
    * `EzagentPluginWorld.WorldLive` — that route's PubSub subscription
    * `Ezagent.World.ConversationActions` — the in-conversation `session.pty.open`
    * `EzagentDomainUi.Pty.TerminalSeam` — the reusable host-LV seam

  Each is an independent path to the same bytes; gating some and not others is
  the same as gating none. The first version of this fix gated two of the four
  and left the conversation path wide open. The policy therefore lives in the PTY
  domain — the thing being protected — and every exit calls it.

  **Any new PTY read exit MUST call `may_read?/2`.**
  """

  alias Ezagent.Capability

  @doc """
  Whether `caps` authorize reading `agent_uri`'s terminal (live output stream or
  scrollback buffer).

  `caps` is the caller's dispatch/socket capability set. Anything that is not a
  capability set is refused rather than raising — a read exit must fail closed.
  """
  @spec may_read?(URI.t(), MapSet.t(Capability.t()) | [Capability.t()] | term()) :: boolean()
  def may_read?(%URI{} = agent_uri, caps) do
    Capability.Authorization.authorizes?(caps, %{
      kind: :agent,
      behavior: Ezagent.ActionSet.Manage,
      action: :read,
      instance: agent_uri,
      workspace_uri: Capability.workspace_of(agent_uri)
    })
  end

  def may_read?(_agent_uri, _caps), do: false
end
