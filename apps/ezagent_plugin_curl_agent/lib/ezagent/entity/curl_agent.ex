defmodule Ezagent.Entity.CurlAgent do
  @moduledoc """
  CurlAgent Kind — an agent that proxies chat messages to a remote
  LLM completion API via HTTP.

  ## URI scheme (PR #141 SPEC v2)

  `entity://agent/team-alpha/curl_<instance_name>` — flavor `curl` prefix on
  the name segment distinguishes from `cc_*` (PTY-based Claude Code
  agents). When the chat router dispatches
  `<receiver>?action=chat.receive`, the BehaviorRegistry maps
  `(CurlAgent, :receive)` straight to `Ezagent.Behavior.CurlAgent`
  without overloading the Agent Kind's receive handler.

  ## Slice shape

      %{
        # config (set at instantiate time, mutable via tools/UI)
        provider:        String.t(),   # "deepseek" / "openai" / ...
        api_url:         String.t(),   # full POST URL
        model:           String.t(),   # provider-specific model id
        system_prompt:   String.t() | nil,
        max_history:     pos_integer(),
        owner_uri:       URI.t(),      # whose api_key to fetch at dispatch

        # state (mutated on each :receive)
        conversation:    [%{role: String.t(), content: String.t()}],
        last_error:      nil | term(),
        last_tokens:     nil | %{prompt: int, completion: int, total: int}
      }

  ## Persistence

  `{:snapshot, :on_change}` — conversation survives phx restart.
  The owner can `:reset` to clear it.

  ## Owner is per-instance, not per-message

  `owner_uri` is set at instantiate (the user who created the
  template — typically admin or self-service via LV) and pins which
  user's api_key the agent uses. This is intentional:

  - If owner_uri == ctx.caller (admin chats with their own agent),
    behaviour is straightforward.
  - If a different user mentions this agent in a shared session
    (e.g. admin creates an agent that other team members use),
    the agent still uses the owner's key — quota goes to the owner,
    not the mentioner. This matches the "I'm paying for this
    bot's usage" model.

  Future: support `owner: :caller` mode that fetches the caller's
  key instead. Not in v1 — keeps the trust story simple.
  """

  @behaviour Ezagent.Kind

  @impl Ezagent.Kind
  def type_name, do: :curl_agent

  @impl Ezagent.Kind
  def behaviors, do: [Ezagent.Behavior.CurlAgent]

  @impl Ezagent.Kind
  def persistence, do: {:snapshot, :on_change}

  # V1 prevention (Allen 2026-05-21): CurlAgent Kinds live under the
  # curl_agent plugin's own InstanceSupervisor. `Ezagent.Kind.spawn/2`
  # reads this.
  @impl Ezagent.Kind
  def supervisor, do: EzagentPluginCurlAgent.InstanceSupervisor
end
