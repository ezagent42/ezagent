defmodule Ezagent.Entity.CurlAgent do
  @moduledoc """
  CurlAgent Kind — an agent that proxies chat messages to a remote
  LLM completion API via HTTP.

  ## URI scheme (PR #141 SPEC v2)

  `entity://agent/team-alpha/curl_<instance_name>` — flavor `curl` prefix on
  the name segment distinguishes from `cc_*` (PTY-based Claude Code
  agents). When the chat router dispatches
  `<receiver>?action=session.receive`, the BehaviorRegistry maps
  `(CurlAgent, :receive)` straight to `Ezagent.Behavior.CurlAgent`
  without overloading the Agent Kind's receive handler.

  ## Slice shape

  Composes the per-Behavior slices listed in `behaviors/0`:

  - `:curl_agent` slice — provider / api_url / model / system_prompt /
    max_history / conversation / last_error / last_tokens
  - `:api_keys` slice (Allen 2026-05-26) — agent's own provider keys
    + `:creator_uri` for the data-owner grant. CurlAgent reads its OWN
    key (`fetch_self_api_key`) at dispatch time.

  ## Persistence

  `{:snapshot, :on_change}` — conversation + keys survive phx restart.
  The owner can `:reset_conversation` to clear; keys are managed via
  the `Behavior.ApiKeys` dispatch surface.

  ## Phase 2-g r3 migration (2026-05-28)

  Adopts `use Ezagent.Kind, pattern: :entity, ...` per SPEC §2.3 +
  §3 composition patterns. Legacy `behaviors/0`, `persistence/0`,
  `type_name/0`, `supervisor/0` callbacks remain — `Kind.Server`
  still reads them — but the macro adds OQ-2 / OQ-5 compile-time
  checks (pattern compatibility + action collision).
  """

  use Ezagent.Kind,
    pattern: :entity,
    type_name: :curl_agent,
    supervisor: EzagentPluginCurlAgent.InstanceSupervisor

  @behaviour Ezagent.Kind

  attach(Ezagent.Behavior.CurlAgent)
  # Allen 2026-05-26 — `Ezagent.Behavior.ApiKeys` listed here so the
  # `:api_keys` slice gets `init_slice`'d at spawn alongside the
  # plugin's own `:curl_agent` slice.
  attach(Ezagent.Behavior.ApiKeys)

  # Kind.Server still reads behaviors/0; keep the legacy callback.
  def behaviors, do: [Ezagent.Behavior.CurlAgent, Ezagent.Behavior.ApiKeys]

  # Kind.Server still reads persistence/0; keep the legacy callback.
  def persistence, do: {:snapshot, :on_change}
end
