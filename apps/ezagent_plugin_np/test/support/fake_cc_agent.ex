defmodule Ezagent.PluginNp.Test.FakeCcAgent do
  @moduledoc """
  Lightweight test stand-in for the real cc-plugin agent — used by the
  comprehensive 4-agent e2e (`comprehensive_4agent_e2e_test.exs`).

  ## Why not reuse the real cc plugin's fake_claude.py?

  The real cc-agent round-trip (fake_claude.py → MCP bridge → WS
  channel → BridgeRegistry → Channel.handle_in("reply")) is already
  proven end-to-end by
  `apps/ezagent_plugin_cc/test/integration/cc_agent_admin_reply_e2e_test.exs`
  (the V1 sign-off test). Reusing that stack in this e2e would:

    - require a Phoenix test endpoint with `/cc_socket`,
    - spawn the uv bridge subprocess + erlexec PTY per cc-agent,
    - add ~30s of cold-start / handshake overhead,
    - make the test slow + flaky for what is fundamentally an
      orchestration validation, not a re-validation of the cc bridge.

  Per the plugin author's judgement (Allen 2026-05-23 brief: "duplicate
  if cross-app sharing is too fiddly — your judgement"), this fake-cc
  is a focused stand-in that mimics the cc-agent's contract:
  receive a chat message → produce a transformed reply (here: wrap as
  a LaTeX integral) → dispatch chat.send back into the session.

  ## What this Behavior simulates from the real cc-agent

    * `chat.receive` → reply with `\\latex{...} = \\int_0^1 x dx`. The
      backslash hints to the downstream agent that this is LaTeX
      (the curl-agent's job is to convert LaTeX → numpy expr).
    * Loop safety — ignores messages whose sender is itself.
    * Reply dispatched under `system://chat-reply` caps (matches the
      real cc Channel's reply path).

  ## Lifecycle migration (post-lifecycle remediation, 2026-05-30)

  Converted from the legacy `@behaviour Ezagent.Behavior` +
  `state_slice/0` / `init_slice/1` / `invoke/4` surface to the
  current `use Ezagent.Lifecycle` developer contract (SPEC
  2026-05-29). The old surface no longer carries the `__behavior__?/0`
  marker the runtime requires, so `Ezagent.Kind.Runtime` REFUSED to
  dispatch to it (`"... is not a new-style Behavior ... Dispatch
  refused."`) — which silently broke the cc→curl leg of the e2e
  chain (the round-trip then timed out at 120s). The reply is now
  expressed as a `{:dispatch, %Ezagent.Cmd{}}` effect rather than a
  direct `Ezagent.Invocation.dispatch/1` inside the handler (per the
  Lifecycle DON'T list).

  ## Registration

  Registered against the EXISTING `Ezagent.Entity.Agent` Kind (the
  generic Agent Kind from `ezagent_domain_session`). The integration
  test's `.exs` setup block binds it transiently to the Agent Kind's
  `:receive` action for the test session, then restores
  `Ezagent.Behavior.Session` in `on_exit`, so the e2e doesn't
  permanently mutate global Behavior bindings. (The binding call
  itself lives in the test, not here — this module is a plain
  Lifecycle Behavior and touches no `*Registry` API, per the
  `:ezagent_plugin_check` §3.2 grep gate.)

  This Behavior lives in `test/support/` and is only compiled in
  `:test` env per `mix.exs` `elixirc_paths(:test)`.
  """

  use Ezagent.Lifecycle, state_slice: :fake_cc

  alias Ezagent.{Cmd, Message}

  action(:receive,
    args: %{message: :map},
    returns: %{},
    caps: [:receive],
    modes: [:cast],
    description: "Transform inbound text to a LaTeX expression and reply into the session"
  )

  # `create/1` — FIRST-EVER existence; build the PERSISTENT state. The
  # FakeCcAgent is registered against the existing Agent Kind, which
  # does NOT list this Behavior in `behaviors/0`, so in practice the
  # slice arrives as `%{}` and the handler reads counts defensively
  # via `ctx.read.(:count, 0)`. Keeping `create/1` makes the slice
  # shape explicit for any future direct-spawn use.
  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{count: 0, last_input: nil}}

  def handle_receive(%{message: %Message{} = msg}, ctx) do
    self_uri_str = uri_string(ctx[:self_uri])
    sender_str = uri_string(msg.sender)

    cond do
      sender_str == self_uri_str ->
        # Loop safety — never reply to our own message.
        {:ok, %{}, []}

      # PR-6 (im/session/agent decomposition §3.5) — the curl agent now
      # spawns on the UNIFIED `Ezagent.Entity.Agent` Kind, the SAME Kind this
      # test double is transiently bound to for `:receive`. The
      # `{Entity.Agent, :receive}` override would otherwise hijack the curl
      # agent too (double-wrapping its input). This double represents ONLY the
      # fake-cc agent (`entity://…/agent/test_cc-…`); every OTHER Entity.Agent
      # (the curl flavor) must flow through the REAL `agent.receive` →
      # AgentBridge → the curl `:in_process_sync` adapter. Delegate it.
      not fake_cc_agent?(self_uri_str) ->
        Ezagent.Behavior.Agent.Receive.handle_receive(%{message: msg}, ctx)

      true ->
        do_receive(msg, ctx)
    end
  end

  # The fake-cc stand-in is the agent whose name segment is `test_cc-<uniq>`
  # (the e2e spawns it as `entity://…/agent/test_cc-<uniq>`). Matched on the
  # full URI string (NOT a positional `%URI{}` field read — that is reserved
  # for `Ezagent.URI` per the URI-query scan invariant).
  defp fake_cc_agent?(self_uri_str) when is_binary(self_uri_str) do
    String.contains?(self_uri_str, "/agent/test_cc")
  end

  defp fake_cc_agent?(_), do: false

  defp do_receive(%Message{} = msg, ctx) do
    inbound_text = extract_text(msg.body)

    # The deterministic LaTeX transformation — wrap the inbound text
    # inside a LaTeX-flavored prefix. The backslash makes the np-agent
    # pick `compute_latex` if it ever sees this directly. The curl-
    # agent's job in the e2e is to convert this LaTeX-ish text into a
    # numpy-acceptable expression.
    latex_reply = "\\latex{" <> inbound_text <> "} = \\int_0^1 x \\, dx"

    count = ctx[:read].(:count, 0)

    reply_effects =
      case reply_effect(ctx[:caller], ctx[:self_uri], latex_reply, msg) do
        nil -> []
        eff -> [eff]
      end

    effects =
      reply_effects ++
        [
          {:set, :count, count + 1},
          {:set, :last_input, inbound_text}
        ]

    {:ok, %{}, effects}
  end

  # Build the `{:dispatch, %Cmd{}}` effect that posts the transformed
  # reply back into the originating session via `chat.send`. Mirrors
  # the real CC agent's reply path (`system://chat-reply`).
  defp reply_effect(nil, _agent_uri, _text, _in_msg), do: nil

  defp reply_effect(%URI{scheme: "session"} = session, agent_uri, text, %Message{} = in_msg) do
    reply_msg = Message.new(agent_uri, %{text: text, attachments: []}, ref_id: in_msg.id)

    {:dispatch,
     %Cmd{
       target: session,
       action: :send,
       args: %{message: reply_msg},
       ctx: %{
         caller: agent_uri,
         caps: "chat-reply" |> Ezagent.SystemPrincipal.uri() |> Ezagent.SystemPrincipal.caps(),
         reply: :ignore
       }
     }}
  end

  defp reply_effect(s, agent_uri, text, in_msg) when is_binary(s) do
    case URI.new(s) do
      {:ok, %URI{scheme: "session"} = u} -> reply_effect(u, agent_uri, text, in_msg)
      _ -> nil
    end
  end

  defp reply_effect(_, _, _, _), do: nil

  defp extract_text(%{text: t}) when is_binary(t), do: t
  defp extract_text(%{"text" => t}) when is_binary(t), do: t
  defp extract_text(_), do: ""

  defp uri_string(%URI{} = u), do: URI.to_string(u)
  defp uri_string(s) when is_binary(s), do: s
  defp uri_string(_), do: ""
end
