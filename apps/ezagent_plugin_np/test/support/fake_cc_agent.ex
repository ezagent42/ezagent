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

    * `chat.receive` → reply with `\\int_0^1 x dx + <inbound>`. The
      backslash hints to the downstream agent that this is LaTeX
      (the curl-agent's job is to convert LaTeX → numpy expr).
    * Loop safety — ignores messages whose sender is itself.
    * Reply dispatched under admin_caps (matches the real cc Channel's
      reply path).

  ## Registration

  Registered against the EXISTING `Ezagent.Entity.Agent` Kind (the
  generic Agent Kind from `ezagent_domain_chat`). The test fixture
  registers it transiently for the test session via
  `Ezagent.BehaviorRegistry.register/3` so the orchestration e2e
  doesn't touch global state permanently.

  This Behavior lives in `test/support/` and is only compiled in
  `:test` env per `mix.exs` `elixirc_paths(:test)`.
  """

  @behaviour Ezagent.Behavior

  alias Ezagent.{Invocation, Message}

  @impl Ezagent.Behavior
  def actions, do: [:receive]

  @impl Ezagent.Behavior
  def cap_subjects do
    [{:receive, "test fixture — fake CC agent's :receive action"}]
  end

  @impl Ezagent.Behavior
  def state_slice, do: :fake_cc

  @impl Ezagent.Behavior
  def init_slice(_args), do: %{count: 0, last_input: nil}

  @impl Ezagent.Behavior
  def invoke(:receive, slice, %{message: %Message{} = msg}, ctx) do
    self_uri_str = URI.to_string(ctx.self_uri)
    sender_str = sender_string(msg.sender)

    if sender_str == self_uri_str do
      {:ok, slice}
    else
      do_receive(slice, msg, ctx)
    end
  end

  @impl Ezagent.Behavior
  def interface do
    %{
      receive: %{
        description: "Transform inbound text to a LaTeX expression and reply into the session",
        args: %{message: :map},
        returns: %{},
        modes: [:cast]
      }
    }
  end

  defp do_receive(slice, msg, ctx) do
    inbound_text = extract_text(msg.body)

    # The deterministic LaTeX transformation — wrap the inbound text
    # inside a LaTeX-flavored prefix. The backslash makes the np-agent
    # pick `compute_latex` if it ever sees this directly. The curl-
    # agent's job in the e2e is to convert this LaTeX-ish text into a
    # numpy-acceptable expression.
    latex_reply = "\\latex{" <> inbound_text <> "} = \\int_0^1 x \\, dx"

    send_reply_to_session(ctx[:caller], ctx.self_uri, latex_reply, msg)

    # The FakeCcAgent is registered against the EXISTING
    # Ezagent.Entity.Agent Kind via BehaviorRegistry, NOT by adding
    # `state_slice: :fake_cc` to the Kind's declared behaviors. As a
    # result `init_slice/1` is never called by Kind.Server — `slice`
    # arrives as `%{}`. Tolerate that: read counts via Map.get/3 and
    # rebuild defensively.
    count = Map.get(slice, :count, 0)
    {:ok, Map.merge(slice, %{count: count + 1, last_input: inbound_text})}
  end

  defp extract_text(%{text: t}) when is_binary(t), do: t
  defp extract_text(%{"text" => t}) when is_binary(t), do: t
  defp extract_text(_), do: ""

  defp sender_string(%URI{} = u), do: URI.to_string(u)
  defp sender_string(s) when is_binary(s), do: s
  defp sender_string(_), do: ""

  defp send_reply_to_session(nil, _, _, _), do: :ok

  defp send_reply_to_session(%URI{scheme: "session"} = session, agent_uri, text, in_msg) do
    msg = Message.new(agent_uri, %{text: text, attachments: []}, ref_id: in_msg.id)
    target = URI.new!("#{URI.to_string(session)}?action=chat.send")

    Invocation.dispatch(%Invocation{
      target: target,
      mode: :cast,
      args: %{message: msg},
      ctx: %{
        caller: agent_uri,
        caps: Ezagent.Entity.User.admin_caps(),
        reply: :ignore
      }
    })

    :ok
  end

  defp send_reply_to_session(s, agent_uri, text, in_msg) when is_binary(s) do
    case URI.new(s) do
      {:ok, %URI{scheme: "session"} = u} -> send_reply_to_session(u, agent_uri, text, in_msg)
      _ -> :ok
    end
  end

  defp send_reply_to_session(_, _, _, _), do: :ok
end
