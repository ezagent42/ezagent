defmodule Ezagent.Domain.Pty.AutoPrompts do
  @moduledoc """
  The well-known startup dialogs a spawned `claude` PTY may pause on, as a
  pure data catalog (Phase 6 PR 19; extracted from `Ezagent.Domain.Pty.Server`
  for the oversized-module arch gate, #89-followup 2026-06-23).

  Each entry is a `%{name, match, send, fired?}` map: the `Server`'s generic
  auto-prompt scanner walks every armed entry against the ANSI-stripped output
  buffer and, on a full `match`, injects `send` to stdin exactly once. Adding a
  new dialog is one entry here — **no scanner code change** (the data-driven
  structure is the whole point). Callers may append extra prompts via the
  `:auto_prompts` spawn arg; this module provides the defaults.

  Match shapes are deliberately FULL (header + option labels + `❯` selection
  markers where a wrong default would be dangerous) rather than loose two-word
  matches: an entry that does not fire at startup stays armed all session, so a
  loose match would later false-positive on ordinary `claude` prose and inject a
  spurious keystroke. See each entry's comment for the per-dialog rationale.
  """

  @typedoc "A single armed auto-prompt entry."
  @type t :: %{name: atom(), match: [String.t()], send: String.t(), fired?: boolean()}

  @doc "The default well-known `claude` startup-dialog auto-prompts."
  @spec default() :: [t()]
  def default do
    [
      %{
        name: :theme_dialog,
        # claude v2.1.x shows a first-run THEME picker the very first time it
        # runs against a fresh CLAUDE_CONFIG_DIR (no onboarding flags). It
        # appears BEFORE the dev-channels / trust-folder dialogs, so an
        # unanswered theme picker hangs the spawn here and the scanner never
        # reaches the dialogs it already handles — the fresh-stack failure seen
        # in the §5.B credential-cascade live E2E (2026-06-07). Bare Enter
        # confirms the highlighted default (claude auto-detects e.g. "Dark mode").
        #
        # Match the FULL menu shape, not just two words: an auto-prompt that does
        # not fire at startup (e.g. theme already persisted) stays armed for the
        # whole session, so a loose match like ["text style", "Dark mode"] would
        # later false-positive on ordinary claude output and inject a spurious
        # Enter (codex review of PR #611). Requiring the header + `/theme` hint +
        # three distinct option labels makes the match specific to this exact
        # dialog — ordinary prose cannot satisfy all five. The radio menu is
        # static (no animated banner), so these labels are not fragmented.
        match: [
          "Choose the text style",
          "/theme",
          "Auto (match terminal)",
          "Dark mode",
          "Light mode"
        ],
        send: "\r",
        fired?: false
      },
      %{
        name: :login_method_dialog,
        # claude v2.1.x shows a "Select login method" picker as part of the SAME
        # first-run onboarding flow as the theme picker — EVEN when a valid
        # `.credentials.json` is already materialized into CLAUDE_CONFIG_DIR. The
        # §5.B credential-cascade live finding (2026-06-07): a materialized cred is
        # NOT sufficient to skip this dialog; claude still asks until onboarding is
        # marked complete. A headless PTY cannot answer it, so the spawn hangs here
        # and the bridge never binds. The durable fix is to mark onboarding complete
        # in the per-agent config (cc plugin's OnboardingBootstrap), so this dialog
        # never appears; this scanner entry is the SAFETY NET for any claude version
        # / config-state that still surfaces it.
        #
        # Option 1 ("Claude account with subscription") is the OAuth/subscription
        # path that USES the materialized credential and is the highlighted default
        # on a Claude Max login; bare Enter confirms it (NOT "2\r", which would pick
        # the Console/API-key path and ignore the materialized OAuth token).
        #
        # Match the FULL menu shape (header + BOTH option labels), not a loose
        # ["login", "subscription"]: an auto-prompt that doesn't fire at startup
        # (onboarding already complete) stays armed all session, so a loose match
        # would later false-positive on ordinary claude prose and inject a spurious
        # Enter (codex review of PR #611 / theme_dialog). The radio menu is static
        # (no animated banner), so these labels are not fragmented.
        #
        # CRUCIAL — the subscription row must carry the SELECTION MARKER `❯`
        # (codex review of PR #718): bare Enter confirms whatever is HIGHLIGHTED,
        # so we only fire when option 1 (the OAuth/subscription path that uses the
        # materialized credential) is the highlighted default. If account/version
        # drift highlights option 2 (Console/API-key) instead, `❯ 1.` is absent →
        # we do NOT fire, never confirming the wrong auth path. (`\e[1C` cursor-
        # forwards strip to single spaces, so the marker row renders as
        # "❯ 1. Claude account with subscription".)
        match: [
          "Select login method",
          "❯ 1. Claude account with subscription",
          "Anthropic Console account"
        ],
        send: "\r",
        fired?: false
      },
      %{
        name: :dev_channels_dialog,
        # Anchor on the menu OPTION label, not the WARNING prose: claude's
        # TUI animates/redraws the banner ("Loading…") with cursor-move
        # escapes, so after ANSI-strip the word can fragment ("L ading"),
        # breaking a literal "Loading development channels" match. The
        # option-1 label is rendered atomically and is specific enough to
        # this exact dialog to avoid false positives.
        # Live #505: the WARNING prose fragments run-to-run ("development channels"
        # -> "developme t channel"), so anchor ONLY on the atomic option-1 label,
        # which is specific enough to this exact dialog. (Sending "1\r" selects it
        # regardless of highlight.)
        match: ["I am using this for local development"],
        send: "1\r",
        fired?: false
      },
      %{
        name: :claude_md_external_imports_dialog,
        # claude 2.x asks "Allow external CLAUDE.md file imports?" the first time a
        # project's CLAUDE.md `@imports` a file OUTSIDE the cwd (e.g. a user-global
        # `~/.claude/RTK.md`). A headless PTY cannot answer it, so the spawn hangs
        # here BEFORE the esr-bridge MCP connects (observed live on claude 2.x,
        # #505, 2026-06-27 — the dialog AFTER the MCP-trust prompt). The agent's
        # own CLAUDE.md / skills depend on those imports, so option 1 ("Yes, allow
        # external imports") is correct. Send the EXPLICIT "1\r" (number-select,
        # like dev_channels/trust_folder) rather than bare Enter so we select
        # option 1 regardless of the current highlight. Match the header + the
        # option-1 label (avoiding redraw-fragmented prose).
        # NOTE both the HEADER prose AND option 2 are redraw-fragmented run to run
        # ("external" -> "ext nal", "disable" -> "d sable"), so they are unusable.
        # Option 1's label was observed rendered atomically; it is specific enough
        # to this exact dialog on its own. (This auto-prompt is a FALLBACK — the
        # primary fix is OnboardingBootstrap pre-setting the project-scoped
        # `hasClaudeMdExternalIncludesApproved` so the dialog never appears.)
        match: ["Yes, allow external imports"],
        send: "1\r",
        fired?: false
      },
      %{
        name: :trust_folder_dialog,
        match: ["Is this a project you", "trust this folder"],
        send: "1\r",
        fired?: false
      },
      %{
        name: :mcp_trust_dialog,
        # claude 2.1.x shows a "New MCP server found" TRUST prompt for servers
        # supplied via `--mcp-config`, EVEN under `--dangerously-skip-permissions`
        # / `--permission-mode bypassPermissions` — the MCP trust gate is SEPARATE
        # from tool-call permissions and is not suppressed by them (observed on
        # claude 2.1.170, 2026-06-10). A headless PTY cannot answer it, so the
        # spawn hangs here and the esr-bridge MCP never starts → the bridge never
        # JOINs (the post-EagerBridge-refactor recurrence of the "0 JOINED" class).
        #
        # The esr-bridge server is FRAMEWORK-supplied + trusted (we wrote the
        # `--mcp-config` ourselves), so confirming option 1 ("Use this MCP server")
        # is correct. Require the `❯ 1.` SELECTION MARKER (mirrors
        # login_method_dialog / codex review of PR #718): bare Enter confirms
        # whatever is HIGHLIGHTED, so we only fire when option 1 is the default —
        # never accidentally landing on "3. Continue without using this MCP server".
        # Match the header + the marked option-1 label (avoiding "server"/"resources"
        # which the TUI redraw fragments after ANSI-strip) so ordinary prose cannot
        # satisfy both while the prompt stays armed all session.
        match: [
          "New MCP server found",
          "❯ 1. Use this MCP server"
        ],
        send: "\r",
        fired?: false
      },
      %{
        name: :bypass_permissions_dialog,
        # claude 2.1.x shows a one-time "Bypass Permissions mode" ACCEPTANCE
        # warning the first time a fresh CLAUDE_CONFIG_DIR runs under
        # `--permission-mode bypassPermissions` / `--dangerously-skip-permissions`
        # ("By proceeding, you accept all responsibility…", options `1. No, exit` /
        # `2. Yes, I accept`). It appears AFTER the MCP-trust prompt and a headless
        # PTY cannot answer it, so the spawn hangs here (claude 2.1.170, 2026-06-10).
        #
        # CRUCIAL — send the EXPLICIT "2\r" (NOT bare Enter): the highlighted
        # default is the SAFE option "1. No, exit", so a bare Enter would QUIT
        # claude. Typing the option number jumps to + selects "2. Yes, I accept"
        # regardless of the current highlight (same number-select form as
        # dev_channels_dialog / trust_folder_dialog). Match the header + the
        # option-2 label (avoiding "approval"/"commands"/"https", which the TUI
        # redraw fragments after ANSI-strip).
        match: ["Bypass Permissions mode", "Yes, I accept"],
        send: "2\r",
        fired?: false
      }
    ]
  end
end
