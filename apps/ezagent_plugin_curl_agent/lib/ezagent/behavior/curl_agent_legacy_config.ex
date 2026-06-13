defmodule Ezagent.Behavior.CurlAgentLegacyConfig do
  @moduledoc """
  Legacy `:reset_conversation` / `:configure` for the OLD
  `Ezagent.Entity.CurlAgent` Kind ONLY (codex round-2 P2, PR-6 rollback
  window).

  ## Why this exists (the cap-axis split)

  PR-6 reparented `Ezagent.Behavior.CurlAgent` onto the UNIFIED
  `Ezagent.Entity.Agent` Kind (curl flavor). Its `required_caps/0` therefore
  pins the `:agent` cap axis (`type_name :agent`) — CORRECT for new curl
  agents, which spawn on `Entity.Agent` and whose grants key on `:agent`.

  BUT `Ezagent.Behavior.CurlAgent` is ALSO kept bound on the LEGACY
  `Ezagent.Entity.CurlAgent` Kind through the rollback window (so existing
  `curl_agent` snapshots still resolve their actions). On that legacy Kind,
  EXISTING curl agents/users hold `:curl_agent` caps — but the reparented
  behavior's `required_caps/0` declares `:agent`, so a non-wildcard caller who
  could previously `reset_conversation` / `configure` a legacy curl agent would
  now be DENIED (the action demands an `:agent` cap nobody legacy holds).

  This companion restores the LEGACY cap axis for those two PUBLIC actions: it
  declares `:curl_agent` caps (`required_caps/0` below) and is bound
  EXCLUSIVELY to `{Entity.CurlAgent, :reset_conversation | :configure}`. The
  reparented `Ezagent.Behavior.CurlAgent` keeps owning them (with `:agent`
  caps) on the UNIFIED `Entity.Agent` Kind. `:sync_result` is NOT here — it
  only flows on the unified Kind (the legacy Kind receives inline via
  `CurlAgentLegacyReceive`).

  It carries NO `state_slice` of its own; it shares the `:curl_agent` slice the
  legacy Kind already materializes via `Ezagent.Behavior.CurlAgent` and mutates
  it via the SAME `{:set, …}` effects the reparented handlers produce (the
  handler bodies are byte-for-byte the reparented ones — only the cap axis
  differs).

  PR-7 deletes this module together with `Entity.CurlAgent` and the
  `CurlAgentLegacyReceive` companion once the snapshots are migrated.
  """

  # Share the legacy Kind's existing `:curl_agent` slice (same rationale as
  # `CurlAgentLegacyReceive`): do NOT auto-derive a fresh slice that would
  # orphan an empty map on a snapshot-on-change agent.
  use Ezagent.Lifecycle, state_slice: :curl_agent

  action(:reset_conversation,
    args: %{},
    returns: %{ok: :boolean},
    caps: [:reset_conversation],
    modes: [:call],
    description: "clear the legacy curl agent's conversation history"
  )

  action(:configure,
    args: %{
      provider: :string,
      api_url: :string,
      model: :string,
      system_prompt: :string,
      max_history: :integer
    },
    returns: %{ok: :boolean},
    caps: [:configure],
    modes: [:call],
    description: "set or update the legacy curl agent's endpoint config (URL, headers, prompt)"
  )

  # The legacy Kind keys on the `:curl_agent` axis (type_name :curl_agent) —
  # the axis EXISTING grants were issued against pre-fold. Manually pinned to
  # override the macro's `:any` default and to keep the legacy authority intact
  # while the reparented `Ezagent.Behavior.CurlAgent` uses `:agent` on
  # `Entity.Agent`.
  def required_caps do
    %{
      reset_conversation:
        Ezagent.Capability.cap(:curl_agent, __MODULE__, :reset_conversation),
      configure: Ezagent.Capability.cap(:curl_agent, __MODULE__, :configure)
    }
  end

  # No `create/1`: this companion owns no fresh state. The shared `:curl_agent`
  # slice is built by `Ezagent.Behavior.CurlAgent.create/1` on the same Kind.

  # ---------------------------------------------------------------
  # handle_<action>/2 — VERBATIM the reparented Behavior.CurlAgent bodies
  # ---------------------------------------------------------------

  def handle_reset_conversation(_args, _ctx) do
    {:ok, %{ok: true},
     [
       {:set, :conversation, []},
       {:set, :last_error, nil}
     ]}
  end

  def handle_configure(args, ctx) when is_map(args) do
    provider = ctx.read.(:provider, "deepseek")
    api_url = ctx.read.(:api_url, "https://api.deepseek.com/chat/completions")
    model = ctx.read.(:model, "deepseek-chat")
    system_prompt = ctx.read.(:system_prompt, nil)
    max_history = ctx.read.(:max_history, 20)

    {:ok, %{ok: true},
     [
       {:set, :provider, Map.get(args, :provider, provider)},
       {:set, :api_url, Map.get(args, :api_url, api_url)},
       {:set, :model, Map.get(args, :model, model)},
       {:set, :system_prompt, Map.get(args, :system_prompt, system_prompt)},
       {:set, :max_history, Map.get(args, :max_history, max_history)}
     ]}
  end

  # caps-data-ownership-v2 (SPEC #306 §7) — a Behavior with caps MUST declare
  # data_owner/1. This companion shares the `:curl_agent` slice on the legacy
  # `Entity.CurlAgent` Kind; its grant authority is the SAME as the reparented
  # `Ezagent.Behavior.CurlAgent` (the `:api_keys` slice's `:creator_uri`), so
  # delegate to keep the ownership formalism identical across the split.
  def data_owner(arg), do: Ezagent.Behavior.CurlAgent.data_owner(arg)
end
