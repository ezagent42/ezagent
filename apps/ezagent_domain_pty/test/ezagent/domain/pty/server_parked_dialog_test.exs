defmodule Ezagent.Domain.Pty.Server.ParkedDialogTest do
  @moduledoc """
  cc-PTY hardening 2026-07-10 (audit #1) — the parked-on-UNKNOWN-dialog signal.

  When a `claude` release ships a selection dialog (`❯`) the auto-prompt catalog
  does not recognize, a headless PTY parks on it and the spawn-time transport
  join later times out with an OPAQUE `{:error, :timeout}`. This detector makes
  the stuck state OBSERVABLE first: after the PTY goes idle on such a dialog it
  EMITS (telemetry + log + PubSub of the ANSI-stripped screen) so the operator
  sees WHAT claude is asking. It never auto-answers an unknown dialog.
  """
  use ExUnit.Case, async: false

  alias Ezagent.Domain.Pty.Server, as: PtyServer

  @idle_ms 100

  setup do
    prev = Application.get_env(:ezagent_domain_pty, :parked_dialog_idle_ms)
    Application.put_env(:ezagent_domain_pty, :parked_dialog_idle_ms, @idle_ms)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:ezagent_domain_pty, :parked_dialog_idle_ms)
        v -> Application.put_env(:ezagent_domain_pty, :parked_dialog_idle_ms, v)
      end
    end)

    :ok
  end

  defp fresh_uri, do: Ezagent.URI.new!("entity://team-alpha/agent/cc_parked-#{System.unique_integer([:positive])}")

  defp start_server(opts \\ %{}) do
    uri = fresh_uri()

    pid =
      start_supervised!(%{
        id: {PtyServer, uri},
        start: {PtyServer, :start_link, [Map.merge(%{agent_uri: uri, test_mode: true}, opts)]}
      })

    {uri, pid}
  end

  test "idle on an UNKNOWN ❯ dialog broadcasts the stripped screen + fires telemetry" do
    {uri, pid} = start_server()
    Phoenix.PubSub.subscribe(EzagentCore.PubSub, PtyServer.parked_dialog_topic(uri))
    attach_telemetry(uri)

    unknown =
      "\r\n╭─ A brand-new claude dialog ─╮\r\n" <>
        "❯ 1. Frobnicate the widget\r\n  2. Cancel\r\n╰──────╯\r\n"

    send(pid, {:stdout, 4242, unknown})

    assert_receive {:pty_parked_unknown_dialog, ^uri, screen}, 1_000
    assert screen =~ "Frobnicate the widget"
    assert screen =~ "❯"

    assert_receive {:telemetry, [:ezagent, :pty, :parked_unknown_dialog], %{count: 1}, meta}, 1_000
    assert meta.agent_uri == uri
    assert meta.screen =~ "Frobnicate the widget"
  end

  test "a KNOWN dialog (matches an armed auto-prompt) does NOT signal parked" do
    # In production the armed prompt would fire + clear the dialog; here (no
    # exec_pid) it stays armed, and the guard still refuses to cry "unknown".
    {uri, pid} = start_server()
    Phoenix.PubSub.subscribe(EzagentCore.PubSub, PtyServer.parked_dialog_topic(uri))

    known_mcp_trust =
      "New MCP server found\r\n" <>
        "❯ 1. Use this MCP server\r\n  2. Continue without\r\n"

    send(pid, {:stdout, 4242, known_mcp_trust})

    refute_receive {:pty_parked_unknown_dialog, ^uri, _screen}, 4 * @idle_ms
  end

  test "idle on ordinary output (no ❯ selection marker) does NOT signal parked" do
    {uri, pid} = start_server()
    Phoenix.PubSub.subscribe(EzagentCore.PubSub, PtyServer.parked_dialog_topic(uri))

    send(pid, {:stdout, 4242, "just some regular streaming output\nno dialog here\n"})

    refute_receive {:pty_parked_unknown_dialog, ^uri, _screen}, 4 * @idle_ms
  end

  test "the same parked screen emits only once (no per-idle-tick spam)" do
    {uri, pid} = start_server()
    Phoenix.PubSub.subscribe(EzagentCore.PubSub, PtyServer.parked_dialog_topic(uri))

    unknown = "❯ 9. Some unknown option the catalog never heard of\r\n"
    send(pid, {:stdout, 4242, unknown})
    assert_receive {:pty_parked_unknown_dialog, ^uri, _screen}, 1_000

    # Nudge the watchdog again WITHOUT changing the screen (append nothing new of
    # substance) — must not re-emit for the identical parked screen.
    send(pid, {:stdout, 4242, ""})
    refute_receive {:pty_parked_unknown_dialog, ^uri, _screen}, 4 * @idle_ms
  end

  defp attach_telemetry(uri) do
    test_pid = self()
    handler_id = {:parked_test, uri, System.unique_integer([:positive])}
    event = [:ezagent, :pty, :parked_unknown_dialog]

    :telemetry.attach(
      handler_id,
      event,
      fn ^event, measurements, metadata, _cfg ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
