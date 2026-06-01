defmodule Ezagent.Domain.Pty.Server.AutoPromptsTest do
  @moduledoc """
  Guards the well-known claude startup dialogs that the PTY auto-prompt
  scanner must auto-answer. If any of these stops matching, the spawned
  `claude` hangs at the dialog → never initializes its MCP servers →
  `esr-bridge` never binds → `EagerBridge.ensure_bound!/2` times out and
  the customer chat shows "Could not reach the assistant".

  The fixtures are REAL `pty_buffer` slices captured from a live spawn on
  a fresh machine (2026-05-30). They keep claude's cursor-move escapes
  (`\\e[1C`) verbatim because the matcher runs on the ANSI-stripped buffer,
  and the stripping (each CSI → one space) is exactly what can fragment a
  word like "Loading" into "L ading" — the failure this test pins down.
  """
  use ExUnit.Case, async: true

  alias Ezagent.AnsiStrip
  alias Ezagent.Domain.Pty.Server, as: PtyServer

  # Real folder-trust dialog ("Is this a project you trust?"), shown the
  # first time claude runs in a cwd not yet recorded as trusted.
  @trust_buffer "\e[1CAccessing\e[1Cworkspace:\r\r\n\e[1C/Users/x/poc-sandbox-phase2/cinnox\r\r\n" <>
                  "\e[1CQuick\e[1Csafety\e[1Ccheck:\e[1CIs\e[1Cthis\e[1Ca\e[1Cproject\e[1Cyou\e[1Ccreated\e[1Cor\e[1Cone\e[1Cyou\e[1Ctrust?\r\r\n" <>
                  "\e[1C\x{276F}\e[1C1.\e[1CYes,\e[1CI\e[1Ctrust\e[1Cthis\e[1Cfolder\r\r\n\e[3C2.\e[1CNo,\e[1Cexit\r\r\n" <>
                  "\e[1CEnter\e[1Cto\e[1Cconfirm\e[1C\x{00B7}\e[1CEsc\e[1Cto\e[1Ccancel"

  # Real dev-channels warning, where claude animates the banner so the
  # "o" of "Loading" is drawn via a cursor move → strips to "L ading".
  @dev_channels_buffer "\e[13A WARNING:\e[1CL\e[1Cading development\e[1Cchannels\r" <>
                         "\e[2B --dangerously-l\e[1Cad-development-chan\e[1Cels\e[1Cis\e[1Cfor\e[1Clocal\e[1Cchannel\e[1Cdevelopment\e[1Conly.\r" <>
                         "\e[2B Channels: server:esr-bridg\e[1C\r" <>
                         "\e[2B \x{276F} 1. I am using\e[1Cthis\e[1Cfor\e[1Clocal\e[1Cdevelopment\r\e[4C\e[1B2.\e[1CExit\r" <>
                         "\e[1BEnter to confirm\e[1C\x{00B7}\e[1CEsc\e[1Cto\e[1Ccancel"

  # Real first-run theme picker ("Let's get started / Choose the text style…"),
  # shown by claude >= ~2.1 whenever it starts in a fresh CLAUDE_CONFIG_DIR
  # (every per-agent cc sandbox is fresh). Captured 2026-06-01 from claude
  # 2.1.92. Each `\e[1C` (cursor-forward) strips to one space, so the prompt
  # line stays readable for substring matching.
  @theme_picker_buffer "Choose\e[1Cthe\e[1Ctext\e[1Cstyle\e[1Cthat\e[1Clooks\e[1Cbest\e[1Cwith\e[1Cyour\e[1Cterminal\e[22m\r\r\n" <>
                          "\e[1C\e[38;5;246mTo\e[1Cchange\e[1Cthis\e[1Clater,\e[1Crun\e[1C/theme\e[39m\r\r\n" <>
                          "\e[1C\x{276F}\e[1C1.\e[1CDark\e[1Cmode\r\r\n\e[3C2.\e[1CLight\e[1Cmode"

  defp spec(name),
    do: Enum.find(PtyServer.default_auto_prompts(), &(&1.name == name))

  test ":theme_picker_dialog fires on the real first-run theme picker, sends Enter, and re-arms" do
    p = spec(:theme_picker_dialog)
    assert p, "theme_picker_dialog must be in default_auto_prompts/0"
    assert PtyServer.matches?(p.match, AnsiStrip.strip(@theme_picker_buffer))
    # bare Enter accepts the pre-highlighted default (safe if it leaks to a
    # later default-highlighted dialog); a stray "1" could land as chat text.
    assert p.send == "\r"
    # the theme picker renders before claude is input-ready, so a one-shot
    # would be eaten and never retry — it MUST re-arm.
    assert Map.get(p, :repeat?) == true
  end

  test ":trust_folder_dialog fires on the real folder-trust buffer and sends \"1\\r\"" do
    p = spec(:trust_folder_dialog)
    assert p, "trust_folder_dialog must be in default_auto_prompts/0"
    assert PtyServer.matches?(p.match, AnsiStrip.strip(@trust_buffer))
    assert p.send == "1\r"
  end

  test ":dev_channels_dialog still fires even though the TUI fragments \"Loading\"" do
    p = spec(:dev_channels_dialog)
    assert p
    assert PtyServer.matches?(p.match, AnsiStrip.strip(@dev_channels_buffer))
    assert p.send == "1\r"
  end

  test "regression: a literal \"Loading development channels\" match would MISS this buffer" do
    # Why :dev_channels_dialog anchors on the menu-option label, not the
    # banner prose: the animated banner strips to "L ading…", so the old
    # literal would silently stop matching and re-hang the PTY.
    stripped = AnsiStrip.strip(@dev_channels_buffer)
    refute String.contains?(stripped, "Loading development channels")
    assert String.contains?(stripped, "development channels")
    assert String.contains?(stripped, "I am using this for local development")
  end

  test "no auto-prompt matches an unrelated buffer (no false positives)" do
    benign = AnsiStrip.strip("\e[1CWelcome\e[1Cback!\e[1CHow\e[1Ccan\e[1CI\e[1Chelp?")

    for p <- PtyServer.default_auto_prompts() do
      refute PtyServer.matches?(p.match, benign),
             "#{p.name} should not match a benign prompt buffer"
    end
  end
end
