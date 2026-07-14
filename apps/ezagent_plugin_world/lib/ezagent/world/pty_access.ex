defmodule Ezagent.World.PtyAccess do
  @moduledoc """
  Who may watch an agent's terminal.

  A PTY's OUTPUT is at least as sensitive as its input — `claude /login`
  authorization codes, secrets echoed by commands, source, the agent's whole
  conversation. Yet the world plugin's two read exits (the `pty_terminal`
  component state and `WorldLive`'s PubSub subscription) both took the agent URI
  straight out of the URL and served the bytes with **no capability check and no
  workspace check**: any authenticated entity could watch any agent's terminal in
  any workspace. Writing was CapBAC-gated all along; only reading was open.

  Allen, 2026-07-14 — **the terminal belongs to the creator**. A creator's
  authority over an agent is the Manage cap they already hold from creation
  (`CreatorGrant.manage_cap/4`; #533 §3.3 — "any management action on THIS
  instance"), and `Ezagent.ActionSet.Pty` gates `:write` / `:restart` on that
  same cap. Reads are gated here on it too, so one authority covers the whole
  terminal:

    * the agent's **creator** holds `cap(:agent, Manage, :any, <that agent>)` —
      already, for every agent that exists today. No new grant, no backfill.
    * **admin**'s genesis wildcard matches everything.
    * **nobody else** matches — `behavior` and `instance` are both exact, so a
      Manage cap on someone else's agent does not open this one.

  This is what makes Allen's 2026-07-10 decision safe: "a user may deliberately
  create a credential-less cc agent and run `claude /login` inside its PTY" only
  holds if nobody else is watching that PTY while they type the code.

  Both read exits MUST call this. Gating one and not the other leaves the second
  serving the same bytes.
  """

  alias Ezagent.Capability

  @doc """
  Whether `caps` authorize watching `agent_uri`'s terminal.

  The needed-cap is the agent's instance-scoped Manage authority. The creator's
  `action: :any` Manage cap matches (`:any` on the held side is the wildcard), as
  does admin's genesis cap; nothing else does.
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
