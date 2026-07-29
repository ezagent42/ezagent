defmodule Ezagent.ActionSet.CurlAgent do
  @moduledoc """
  CurlAgent Behavior — the curl flavor's STATE half on the unified
  `Ezagent.Entity.Agent` Kind.

  ## PR-6 fold (im/session/agent decomposition, codex HIGH-1)

  Per SPEC
  `docs/superpowers/specs/2026-06-12-im-session-agent-decomposition-design.md`
  §3.5 / §OQ-1, curl is decomposed into a STATE Behavior (this module) and
  a TRANSPORT adapter (`EzagentPluginCurlAgent.BridgeAdapter`,
  `transport_class :in_process_sync`). curl is STATEFUL; the adapter is
  NOT.

  This Behavior is **REPARENTED onto `Ezagent.Entity.Agent`** and composed
  into the per-instance behavior set ONLY for the `curl` flavor (via the
  same `:kind_base` per-instance-set mechanism the Session Kind uses).

  ## PR-9c (#53) — physically relocated into the agent domain

  As of PR-9c the module FILE lives in `ezagent_domain_agent` (alongside
  `Entity.Agent`), not in the curl plugin. `Entity.Agent.behaviors/0` /
  `curl_behaviors/0` already named it as the agent Kind's curl-flavor state
  half, so keeping the code in the plugin was a domain → plugin upward
  reference. Moving it makes the agent domain a clean leaf (the acyclic gate's
  agent → plugin allowlist reaches 0). The curl plugin still owns the curl
  flavor WIRING (binds the actions to this Behavior, plus the template /
  adapter / flavor); it now depends on this domain to reference the module.
  The module name `Ezagent.ActionSet.CurlAgent` is frozen (snapshot keys + the
  plugin's binding registration). It depends only on core symbols.

  It keeps:

    * the `:curl_agent` slice (provider / api_url / model / system_prompt /
      max_history / conversation / last_error / last_tokens),
    * the PUBLIC `reset_conversation` / `configure` actions,
    * ALL the durable `{:set, :conversation/:last_error/:last_tokens}`
      effects,
    * the `session.send` reply dispatch.

  What it SHEDS is the in-process HTTP round-trip (`run_completion/6` +
  `ApiClient`) — that moved to the adapter. The old `:receive` action is
  GONE: receive now flows through `agent.receive`
  (`Ezagent.ActionSet.Agent.Receive`) → `AgentBridge.deliver` → the curl
  adapter (the `:in_process_sync` HTTP round-trip).

  ## The `:sync_result` seam (the post-HTTP persist step)

  `agent.receive` is flavor-blind. For the `:in_process_sync` class it
  calls the adapter, gets back `{:ok, %{content, usage, user_text}}` /
  `{:error, reason}` SYNCHRONOUSLY, and re-dispatches that result to this
  Behavior's `:sync_result` action (SPEC §9 tension 3). `handle_sync_result/2`
  is where the durable conversation mutation lives:

    1. append `{role: "user", content: user_text}` then `{role:
       "assistant", content: content}` to `conversation`, trim to
       `max_history`, `{:set, :conversation, …}` + `{:set, :last_tokens,
       usage}` + `{:set, :last_error, nil}`;
    2. on `{:error, reason}` set `last_error` (and, for `{:no_api_key, _}`,
       append only the user turn) and dispatch a STRUCTURED error reply
       (`Ezagent.Agent.ErrorSignal` — G5 source 2, no hand-written prose);
    3. dispatch the reply back into the originating session via
       `session.send`.

  **The adapter delivers; this Behavior owns state/effects.** The adapter
  reads the persisted slices to ASSEMBLE the request (deadlock-safe
  snapshot reads) but NEVER persists; this Behavior performs every
  `{:set, …}`.

  ## Persistent state (auto-derived state_slice :curl_agent)

  All fields are PERSISTENT (no transients). `create/1` builds the initial
  state; `reset_conversation`/`configure`/`sync_result` mutate it via
  `{:set, …}` effects. The auto-derived `state_slice/0` (last module
  segment `CurlAgent` → `:curl_agent`) equals the historical snapshot key,
  so NO `state_slice:` override is needed.

  ## Caller cap

  The reply dispatch presents the target-issued narrow `session.send` artifact
  supplied by the `agent.receive` framework path.
  """

  use Ezagent.Lifecycle

  require Logger

  alias Ezagent.{Cmd, Message}
  alias Ezagent.Agent.ErrorSignal

  action(:reset_conversation,
    args: %{},
    returns: %{ok: :boolean},
    caps: [:reset_conversation],
    modes: [:call],
    description: "clear the curl agent's conversation history"
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
    description: "set or update the curl agent's endpoint config (URL, headers, prompt)"
  )

  # PR-6 (im/session/agent decomposition §3.5 / §9 tension 3) — the
  # post-HTTP persist step. `agent.receive` re-dispatches the curl
  # adapter's `:in_process_sync` result HERE; this Behavior owns the
  # durable conversation/token/error mutation + the session reply. The
  # adapter is transport-only and persists nothing.
  action(:sync_result,
    # `result` is the adapter's `{:ok, %{content, usage}} | {:error, term}` —
    # a structurally-varied tuple this handler pattern-matches itself, hence
    # `:term`. `source_session` is the originating session URI.
    args: %{result: :term, source_session: {:option, :uri}, user_text: :string},
    returns: %{ok: :boolean, tokens: :integer, error: :atom},
    caps: [:sync_result],
    modes: [:cast],
    description: "persist the curl in-process-sync transport result + reply into the session"
  )

  # PR-6+7 — the reparented Behavior lives on the unified `Ezagent.Entity.Agent`
  # Kind (type_name :agent), so its cap subjects key on the `:agent` axis. The
  # old standalone curl Kind (keyed on `:curl_agent`) is DELETED; the
  # `:curl_agent → :agent` cap-axis migration for pre-fold agents ran (once,
  # forward-only, no rollback window) via the now-deleted
  # `mix ezagent.curl.migrate` / `Ezagent.PluginCurlAgent.CurlSnapshotMigration`
  # — retired with the rest of that one-shot's machinery since the system never
  # reached production and there was no live `curl_agent` row left to migrate
  # (chore/retire-dead-kind-migrations). Manually exported to override the
  # macro's `:any` default, mirroring how other agent-flavor behaviors pin
  # their kind axis.
  def required_caps do
    %{
      reset_conversation: Ezagent.Capability.cap(:agent, __MODULE__, :reset_conversation),
      configure: Ezagent.Capability.cap(:agent, __MODULE__, :configure),
      sync_result: Ezagent.Capability.cap(:agent, __MODULE__, :sync_result)
    }
  end

  # Allen 2026-05-26 — declare the sibling state this Behavior reads
  # in-process. `:api_keys` lives on the SAME Agent Kind. The receive-time
  # key fetch moved to the adapter (snapshot read), but the declaration is
  # retained for `BehaviorSet` closure parity (`@required_reads` lists
  # `CurlAgent => %{api_keys: :optional}`) + `data_owner/1`'s key lookup.
  reads_siblings([:api_keys])

  # `create/1` — build the initial PERSISTENT `:curl_agent` state once, on
  # first-ever existence. No transients (all fields survive restart), so
  # `activate/2` is the macro-injected no-op default.
  @impl Ezagent.Lifecycle
  def create(args) do
    {:ok,
     %{
       # codex P1 (PR-6) — the flavor is a DURABLE slice field (O-2: flavor
       # is STORED state, not an ETS-only launch attribute). Persisting it in
       # the `:curl_agent` slice that THIS Behavior owns means a cold-load
       # (rehydrate from `kind_snapshots`, no ETS) still resolves the curl
       # `:in_process_sync` transport — `resolve_delivery_flavor/1` reads it
       # from the snapshot store. The ETS `AgentFlavorAttributes` row stays an
       # OPTIONAL fast-path, never the sole source.
       flavor: "curl",
       provider: Map.get(args, :provider, "deepseek"),
       api_url: Map.get(args, :api_url, "https://api.deepseek.com/chat/completions"),
       model: Map.get(args, :model, "deepseek-chat"),
       system_prompt: Map.get(args, :system_prompt),
       max_history: Map.get(args, :max_history, 20),
       conversation: [],
       last_error: nil,
       last_tokens: nil
     }}
  end

  # ---------------------------------------------------------------
  # handle_<action>/2
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

  @doc """
  Persist the curl adapter's `:in_process_sync` round-trip result and reply
  into the originating session (PR-6 §3.5).

  `args.result` is the adapter's return:

    * `{:ok, %{content, usage, user_text}}` — append the user + assistant
      turns, trim to `max_history`, set tokens, clear error, reply with the
      assistant content;
    * `{:error, {:no_api_key, provider}}` — append the user turn only, set
      `last_error`, reply with the STRUCTURED error body (G5 source 2);
    * `{:error, reason}` — append the user turn only, set `last_error`,
      reply with the STRUCTURED error body.

  `args.source_session` is the session URI the reply is dispatched back to.
  This handler owns EVERY durable `{:set, …}` mutation — the adapter
  persists nothing.
  """
  def handle_sync_result(%{result: result} = args, ctx) do
    source_session_uri = Map.get(args, :source_session)
    self_uri = Map.get(ctx, :self_uri)
    max_history = ctx.read.(:max_history, 20)
    current_conv = ctx.read.(:conversation, [])

    user_text = Map.get(args, :user_text, "")
    in_msg_id = Map.get(args, :in_msg_id)
    reply_cap = Map.get(args, :reply_cap)

    case result do
      {:ok, %{content: reply, usage: usage}} ->
        final_conv =
          current_conv
          |> append_turn("user", user_text)
          |> append_turn("assistant", reply)
          |> trim(max_history)

        effects =
          [
            {:set, :conversation, final_conv},
            {:set, :last_error, nil},
            {:set, :last_tokens, usage}
          ] ++ maybe_reply_effect(source_session_uri, self_uri, reply, in_msg_id, reply_cap)

        {:ok, %{ok: true, tokens: usage.total}, effects}

      {:error, {:no_api_key, provider}} ->
        effects =
          [
            {:set, :conversation,
             current_conv |> append_turn("user", user_text) |> trim(max_history)},
            {:set, :last_error, {:no_api_key, provider}}
          ] ++
            maybe_reply_error(
              source_session_uri,
              self_uri,
              {:no_api_key, provider},
              in_msg_id,
              reply_cap
            )

        {:ok, %{ok: false, error: :no_api_key}, effects}

      {:error, reason} ->
        if is_struct(self_uri, URI) do
          Logger.warning(
            "CurlAgent #{URI.to_string(self_uri)} completion error: #{inspect(reason)}"
          )
        end

        effects =
          [
            {:set, :conversation,
             current_conv |> append_turn("user", user_text) |> trim(max_history)},
            {:set, :last_error, reason}
          ] ++ maybe_reply_error(source_session_uri, self_uri, reason, in_msg_id, reply_cap)

        {:ok, %{ok: false, error: error_kind(reason)}, effects}
    end
  end

  # --- internals --------------------------------------------------------

  defp append_turn(conv, role, content), do: conv ++ [%{role: role, content: content}]

  defp trim(conv, max_history) when length(conv) <= max_history, do: conv
  defp trim(conv, max_history), do: Enum.take(conv, -max_history)

  # Build a single `{:dispatch, %Cmd{}}` effect when source session +
  # self URI are both well-formed; otherwise emit nothing. `text_or_body`
  # is the success reply text (binary) or an already-built body map.
  defp maybe_reply_effect(nil, _self_uri, _text, _in_msg_id, _reply_cap), do: []
  defp maybe_reply_effect("", _self_uri, _text, _in_msg_id, _reply_cap), do: []
  defp maybe_reply_effect(_, nil, _text, _in_msg_id, _reply_cap), do: []

  defp maybe_reply_effect(session_uri, %URI{} = self_uri, text_or_body, in_msg_id, reply_cap) do
    case parse_session_uri(session_uri) do
      nil ->
        []

      %URI{} = session ->
        reply_msg = Message.new(self_uri, reply_body(text_or_body), ref_id: in_msg_id)
        target = Ezagent.URI.with_action(session, :session, :send)

        cmd =
          Cmd.new(target, :send, %{message: reply_msg}, %{
            caller: self_uri,
            authenticated_principal: self_uri,
            caps: MapSet.new(List.wrap(reply_cap)),
            reply: :ignore
          })

        [{:dispatch, cmd}]
    end
  end

  # G5 source 2 (async agent-reply errors) — error branches reply with the
  # STRUCTURED error body: pure reason data under `error` + the uniform
  # minimal fallback `text` for degraded surfaces. The world render side
  # decodes it into the SAME ErrorMatcher/ErrorRenderer pipeline the sync
  # dispatch path uses (per-viewer Layer 1/2/3). No hand-written prose here.
  defp maybe_reply_error(session_uri, self_uri, reason, in_msg_id, reply_cap) do
    maybe_reply_effect(
      session_uri,
      self_uri,
      ErrorSignal.reply_body(reason),
      in_msg_id,
      reply_cap
    )
  end

  defp reply_body(text) when is_binary(text), do: %{text: text, attachments: []}
  defp reply_body(%{} = body), do: body

  defp parse_session_uri(%URI{scheme: "session"} = u), do: u

  defp parse_session_uri(s) when is_binary(s) do
    try do
      case Ezagent.URI.new!(s) do
        %URI{scheme: "session"} = u -> u
        _ -> nil
      end
    rescue
      ArgumentError -> nil
    end
  end

  defp parse_session_uri(_), do: nil

  defp error_kind({:http, _, _}), do: :http_error
  defp error_kind({:transport, _}), do: :transport_error
  defp error_kind({:decode, _}), do: :decode_error
  defp error_kind(_), do: :other

  # Allen 2026-05-26 — the data owner is the entity URI recorded in the
  # `:api_keys` slice's `:creator_uri`.
  def data_owner(%URI{scheme: "entity"} = agent_uri) do
    if Ezagent.URI.type?(agent_uri, :agent) do
      case Ezagent.Kind.read(agent_uri, :api_keys, spawn: :never) do
        {:ok, %{creator_uri: %URI{} = creator}} -> creator
        _ -> :no_owner
      end
    else
      :no_owner
    end
  end

  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner
end
