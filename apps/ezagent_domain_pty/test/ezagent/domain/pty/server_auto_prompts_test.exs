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
                  "\e[1C\u276F\e[1C1.\e[1CYes,\e[1CI\e[1Ctrust\e[1Cthis\e[1Cfolder\r\r\n\e[3C2.\e[1CNo,\e[1Cexit\r\r\n" <>
                  "\e[1CEnter\e[1Cto\e[1Cconfirm\e[1C\u00B7\e[1CEsc\e[1Cto\e[1Ccancel"

  # Real dev-channels warning, where claude animates the banner so the
  # "o" of "Loading" is drawn via a cursor move → strips to "L ading".
  @dev_channels_buffer "\e[13A WARNING:\e[1CL\e[1Cading development\e[1Cchannels\r" <>
                         "\e[2B --dangerously-l\e[1Cad-development-chan\e[1Cels\e[1Cis\e[1Cfor\e[1Clocal\e[1Cchannel\e[1Cdevelopment\e[1Conly.\r" <>
                         "\e[2B Channels: server:esr-bridg\e[1C\r" <>
                         "\e[2B \u276F 1. I am using\e[1Cthis\e[1Cfor\e[1Clocal\e[1Cdevelopment\r\e[4C\e[1B2.\e[1CExit\r" <>
                         "\e[1BEnter to confirm\e[1C\u00B7\e[1CEsc\e[1Cto\e[1Ccancel"

  # Real first-run THEME picker, shown by claude v2.1.x the very first time it
  # runs against a fresh CLAUDE_CONFIG_DIR (no onboarding flags). It appears
  # BEFORE the dev-channels / trust-folder dialogs, so if it is not answered the
  # spawn hangs here and never reaches the dialogs the scanner already handles —
  # the fresh-stack failure observed in the §5.B live E2E (2026-06-07). The menu
  # is a static radio list (no animated banner), so words are not fragmented; we
  # still anchor on two stable, dialog-specific phrases. The default-highlighted
  # option (claude auto-detects "Dark mode ✔"); bare Enter confirms the highlight.
  @theme_buffer "\e[1CLet's\e[1Cget\e[1Cstarted.\r\r\n" <>
                  "\e[1CChoose\e[1Cthe\e[1Ctext\e[1Cstyle\e[1Cthat\e[1Clooks\e[1Cbest\e[1Cwith\e[1Cyour\e[1Cterminal\r\r\n" <>
                  "\e[1CTo\e[1Cchange\e[1Cthis\e[1Clater,\e[1Crun\e[1C/theme\r\r\n" <>
                  "\e[1C1.\e[1CAuto\e[1C(match\e[1Cterminal)\r\r\n" <>
                  "\e[1C\u276F\e[1C2.\e[1CDark\e[1Cmode\e[1C\u2714\r\r\n" <>
                  "\e[3C3.\e[1CLight\e[1Cmode\r\r\n"

  # Real first-run LOGIN-METHOD picker, shown by claude v2.1.x when it starts a
  # first-run flow (no onboarding-completion marker yet) — EVEN when a valid
  # `.credentials.json` is present in `CLAUDE_CONFIG_DIR`. It appears AFTER the
  # theme picker in the same onboarding sequence (the §5.B credential-cascade
  # live finding 2026-06-07: a materialized cred is NOT enough — claude still
  # shows "Select login method" until onboarding is marked complete). A headless
  # PTY cannot answer it, so the spawn hangs here and the bridge never binds.
  #
  # Option 1 ("Claude account with subscription") is the OAuth/subscription path
  # that USES the materialized `.credentials.json`; it is the highlighted default
  # on a Claude Max login. Bare Enter confirms the highlighted default → claude
  # proceeds with the materialized OAuth token (no Console/API-key prompt). The
  # menu is a static radio list (no animated banner), so words are not fragmented.
  @login_method_buffer "\e[1CSelect\e[1Clogin\e[1Cmethod:\r\r\n" <>
                          "\e[1CUse\e[1Cyour\e[1Csubscription\e[1Cor\e[1CAPI\e[1Caccount\r\r\n" <>
                          "\e[1C\u276F\e[1C1.\e[1CClaude\e[1Caccount\e[1Cwith\e[1Csubscription\r\r\n" <>
                          "\e[3C2.\e[1CAnthropic\e[1CConsole\e[1Caccount\r\r\n" <>
                          "\e[1CEnter\e[1Cto\e[1Cconfirm\e[1C\u00B7\e[1CEsc\e[1Cto\e[1Cexit"

  # SAME menu, but the selection marker `❯` is on option 2 (Console/API-key)
  # instead of option 1 — account/version drift could render this. Bare Enter
  # here would pick the WRONG auth path, so the prompt MUST NOT fire (codex PR
  # #718): the matcher requires `❯ 1.` on the subscription row.
  @login_method_buffer_opt2_highlighted "\e[1CSelect\e[1Clogin\e[1Cmethod:\r\r\n" <>
                          "\e[1CUse\e[1Cyour\e[1Csubscription\e[1Cor\e[1CAPI\e[1Caccount\r\r\n" <>
                          "\e[3C1.\e[1CClaude\e[1Caccount\e[1Cwith\e[1Csubscription\r\r\n" <>
                          "\e[1C\u276F\e[1C2.\e[1CAnthropic\e[1CConsole\e[1Caccount\r\r\n" <>
                          "\e[1CEnter\e[1Cto\e[1Cconfirm\e[1C\u00B7\e[1CEsc\e[1Cto\e[1Cexit"

  defp spec(name),
    do: Enum.find(PtyServer.default_auto_prompts(), &(&1.name == name))

  test ":theme_dialog fires on the real first-run theme picker and sends \"\\r\" to confirm the highlighted default" do
    p = spec(:theme_dialog)
    assert p, "theme_dialog must be in default_auto_prompts/0"
    assert PtyServer.matches?(p.match, AnsiStrip.strip(@theme_buffer))
    assert p.send == "\r"
  end

  test ":theme_dialog does not match the dev-channels or trust-folder buffers (no cross-fire)" do
    p = spec(:theme_dialog)
    refute PtyServer.matches?(p.match, AnsiStrip.strip(@dev_channels_buffer))
    refute PtyServer.matches?(p.match, AnsiStrip.strip(@trust_buffer))
  end

  test ":theme_dialog stays armed all session but does NOT fire on ordinary output mentioning the words" do
    # An auto-prompt that never fires at startup (e.g. the theme was already
    # persisted, so the picker never appears) remains armed for the whole
    # session and is matched against the live buffer on every scan. A loose
    # match would then inject a spurious Enter when normal claude output happens
    # to contain the words — codex review of PR #611. The full-menu-shape match
    # must reject ordinary prose that merely mentions "text style"/"Dark mode".
    p = spec(:theme_dialog)

    ordinary =
      AnsiStrip.strip(
        "\e[1CSure!\e[1CHere's\e[1Chow\e[1Cto\e[1Cset\e[1Cthe\e[1Ctext\e[1Cstyle\e[1Cto\e[1CDark\e[1Cmode\r\r\n" <>
          "\e[1Cin\e[1Cyour\e[1Ceditor\e[1Csettings.\e[1CRun\e[1C/theme\e[1Cto\e[1Cchange\e[1Cit\e[1Clater."
      )

    refute PtyServer.matches?(p.match, ordinary),
           "theme_dialog must not fire on ordinary output that merely mentions the words + /theme"
  end

  test ":login_method_dialog fires on the real login-method picker and sends \"\\r\" to confirm the highlighted subscription default" do
    p = spec(:login_method_dialog)
    assert p, "login_method_dialog must be in default_auto_prompts/0"
    assert PtyServer.matches?(p.match, AnsiStrip.strip(@login_method_buffer))

    # Bare Enter confirms the highlighted default (option 1 = Claude account with
    # subscription), which is the path that USES the materialized OAuth credential.
    assert p.send == "\r"
  end

  test ":login_method_dialog does not cross-fire on the theme / dev-channels / trust buffers" do
    p = spec(:login_method_dialog)
    refute PtyServer.matches?(p.match, AnsiStrip.strip(@theme_buffer))
    refute PtyServer.matches?(p.match, AnsiStrip.strip(@dev_channels_buffer))
    refute PtyServer.matches?(p.match, AnsiStrip.strip(@trust_buffer))
  end

  test ":login_method_dialog stays armed all session but does NOT fire on ordinary output mentioning the words" do
    # Same armed-all-session hazard as :theme_dialog (codex PR #611): if the
    # login picker never appears (onboarding already complete) the prompt stays
    # armed; a loose match would inject a spurious Enter on ordinary claude prose
    # that happens to say "login" / "subscription". The full-menu-shape match
    # (header + both option labels) rejects ordinary prose.
    p = spec(:login_method_dialog)

    ordinary =
      AnsiStrip.strip(
        "\e[1CTo\e[1Cswitch\e[1Caccounts,\e[1Crun\e[1C/login\e[1Cand\e[1Cpick\e[1Cyour\r\r\n" <>
          "\e[1CClaude\e[1Caccount\e[1Cwith\e[1Csubscription\e[1Cor\e[1Cthe\e[1CConsole."
      )

    refute PtyServer.matches?(p.match, ordinary),
           "login_method_dialog must not fire on ordinary output that merely mentions the words"
  end

  test ":login_method_dialog does NOT fire when option 2 (Console/API-key) is highlighted (codex PR #718)" do
    # The picker is present but the WRONG option is highlighted. Bare Enter would
    # confirm the Console/API-key path and ignore the materialized OAuth token, so
    # the matcher must require `❯ 1.` on the subscription row and NOT fire here.
    p = spec(:login_method_dialog)

    refute PtyServer.matches?(p.match, AnsiStrip.strip(@login_method_buffer_opt2_highlighted)),
           "login_method_dialog must NOT auto-confirm when option 2 is the highlighted default"
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

  # Live #505: on a real run the WARNING prose fragmented WORD-INTERNALLY
  # ("development channels" -> "developme t channel"), which a prose-anchored
  # match would miss. The option-1 label stays atomic, so the rule must still fire.
  test ":dev_channels_dialog fires when the warning prose fragments word-internally" do
    p = spec(:dev_channels_dialog)
    live = "Lo ding developme t channel  --dangerously-load-development-channels ... " <>
             "Channels: server:esr-bridge  ❯   1.  I am using this for local development   2.  Exit"
    assert PtyServer.matches?(p.match, live)
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
