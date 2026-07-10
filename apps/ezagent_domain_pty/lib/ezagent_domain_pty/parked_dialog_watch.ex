defmodule Ezagent.Domain.Pty.ParkedDialogWatch do
  @moduledoc """
  Parked-on-UNKNOWN-dialog detector for `Ezagent.Domain.Pty.Server` (cc-PTY
  hardening 2026-07-10 — audit `docs/notes/2026-07-10-cc-pty-pitfalls.md` #1).
  Extracted from `Server` to keep it under the oversized-module arch gate, the
  same pattern as `Ezagent.Domain.Pty.AutoPrompts`.

  ## What it does

  When a `claude` release ships a selection dialog the auto-prompt catalog does
  not recognize, a headless PTY parks on it: the bridge never joins and the
  spawn-time transport-join gate eventually fails with an OPAQUE
  `{:error, :timeout}` that names nothing. This detector makes the stuck state
  OBSERVABLE first. The `Server` (re)arms a one-shot idle timer on every output
  chunk; when output has been silent long enough it calls `check/4`, which — if
  the idle screen carries claude's `❯` selection marker and no ARMED auto-prompt
  can answer it — EMITS a loud, screen-bearing signal:

    * a `Logger.warning` naming the stuck screen,
    * telemetry `[:ezagent, :pty, :parked_unknown_dialog]`, and
    * a PubSub broadcast `{:pty_parked_unknown_dialog, agent_uri, screen}`.

  It is EMIT-ONLY — it never writes to the PTY stdin. Auto-answering a dialog we
  do not recognize is unsafe (a wrong default could pick "exit" / an API-key
  path / decline a trust prompt), so the fix is to surface the screen, not guess.

  A per-screen signature dedupes: a screen that stays parked emits once, a NEW
  unknown dialog emits again.
  """

  require Logger

  @doc """
  Decide whether the idle PTY screen is an unknown parked dialog and, if so, emit
  the stuck-screen signal.

  * `stripped` — the ANSI-stripped, whitespace-normalized current screen.
  * `armed_match?` — whether some armed (unfired) auto-prompt already matches this
    screen (a KNOWN dialog the Server will answer → not "stuck").
  * `last_signature` — the screen we last emitted for (dedupe), or `nil`.

  Returns `{:emitted, signature}` when it emitted (caller stores the signature),
  or `:noop`.
  """
  @spec check(URI.t(), binary(), boolean(), String.t() | nil) ::
          {:emitted, String.t()} | :noop
  def check(%URI{} = agent_uri, stripped, armed_match?, last_signature)
      when is_binary(stripped) do
    cond do
      not dialog_shaped?(stripped) -> :noop
      armed_match? -> :noop
      stripped == last_signature -> :noop
      true -> emit(agent_uri, stripped)
    end
  end

  @doc """
  PubSub topic for an agent's parked-unknown-dialog signal. Subscribers receive
  `{:pty_parked_unknown_dialog, agent_uri, screen}`.
  """
  @spec topic(URI.t()) :: String.t()
  def topic(%URI{} = agent_uri), do: "pty:parked_dialog:" <> URI.to_string(agent_uri)

  # A `❯` selection marker is claude's radio-menu cursor — its presence in an
  # idle screen means a selection dialog is on screen. The normal REPL input box
  # does not render `❯`, so this does not fire on an ordinary idle prompt.
  defp dialog_shaped?(stripped), do: String.contains?(stripped, "❯")

  defp emit(%URI{} = agent_uri, stripped) do
    screen = screen_excerpt(stripped)

    Logger.warning(
      "PtyServer: PARKED on an UNKNOWN dialog for #{URI.to_string(agent_uri)} — the PTY has " <>
        "gone idle on a selection dialog (❯) that matches no known auto-prompt; a headless " <>
        "PTY cannot answer it, so the transport-join will time out. claude is stuck on: " <>
        inspect(screen)
    )

    :telemetry.execute(
      [:ezagent, :pty, :parked_unknown_dialog],
      %{count: 1},
      %{agent_uri: agent_uri, screen: screen}
    )

    Phoenix.PubSub.broadcast(
      EzagentCore.PubSub,
      topic(agent_uri),
      {:pty_parked_unknown_dialog, agent_uri, screen}
    )

    {:emitted, stripped}
  end

  # Bound the broadcast payload to the trailing screen so a large buffer does not
  # push megabytes through PubSub. The tail carries the current dialog.
  defp screen_excerpt(stripped) do
    trimmed = String.trim(stripped)
    n = String.length(trimmed)
    if n > 2_000, do: String.slice(trimmed, n - 2_000, 2_000), else: trimmed
  end
end
