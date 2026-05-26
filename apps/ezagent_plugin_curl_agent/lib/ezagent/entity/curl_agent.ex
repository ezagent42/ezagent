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

  Composes the per-Behavior slices listed in `behaviors/0`:

  - `:curl_agent` slice — provider / api_url / model / system_prompt /
    max_history / conversation / last_error / last_tokens
  - `:api_keys` slice (Allen 2026-05-26) — agent's own provider keys
    + `:creator_uri` for the data-owner grant. CurlAgent reads its OWN
    key (`fetch_self_api_key`) at dispatch time, not a foreign user's.

  ## Persistence

  `{:snapshot, :on_change}` — conversation + keys survive phx restart.
  The owner can `:reset` to clear the conversation; keys are managed
  via the `Behavior.ApiKeys` dispatch surface.
  """

  @behaviour Ezagent.Kind

  @impl Ezagent.Kind
  def type_name, do: :curl_agent

  # Allen 2026-05-26 — `Ezagent.Behavior.ApiKeys` listed here so the
  # `:api_keys` slice gets `init_slice`'d at spawn alongside the
  # plugin's own `:curl_agent` slice. `CapabilityRegistry.register/3`
  # for ApiKeys against CurlAgent Kind lives in
  # `EzagentPluginCurlAgent.Application` (the same place the plugin's
  # own Behavior is registered).
  @impl Ezagent.Kind
  def behaviors, do: [Ezagent.Behavior.CurlAgent, Ezagent.Behavior.ApiKeys]

  @impl Ezagent.Kind
  def persistence, do: {:snapshot, :on_change}

  # V1 prevention (Allen 2026-05-21): CurlAgent Kinds live under the
  # curl_agent plugin's own InstanceSupervisor. `Ezagent.Kind.spawn/2`
  # reads this.
  @impl Ezagent.Kind
  def supervisor, do: EzagentPluginCurlAgent.InstanceSupervisor
end
