defmodule Ezagent.Domain.Pty.AuthObservers do
  @moduledoc """
  Emit-only auth-failure OBSERVERS for `Ezagent.Domain.Pty.Server` (#17 PR-C).
  Extracted from `Server` to keep it under the oversized-module arch gate — the
  same pattern as `Ezagent.Domain.Pty.AutoPrompts` / `ParkedDialogWatch`.

  Each observer carries the same match shapes as an auto-prompt, but on a match
  it only EMITS — telemetry + a `{:pty_auth_failed, agent_uri, name}` broadcast —
  and NEVER writes to the PTY stdin (that is `AutoPrompts`' job). It surfaces an
  expired or missing login (cc "Please run /login" / 403, codex 401) instead of a
  silent mute. `fired?` makes each signal one-shot.

  ## What these are NOT (2026-07-13)

  They are a **notification** surface, not a liveness signal, and nothing that
  decides whether to keep a child alive may depend on them. Live on canary, an
  agent crash-looped 933 times in two hours and these observers fired **zero**
  times: the child was dying on `claude --continue` finding no resumable
  conversation, which prints none of the credential strings they match. Hooking
  the respawn breaker to this detector — the obvious move, and the one the
  original handoff prescribed — would have produced a green test suite and an
  unchanged production loop.

  The breaker therefore keys off the SHAPE of the failure (a child that never
  reaches a healthy lifetime), not its diagnosis. See
  `Ezagent.Domain.Pty.RespawnPolicy` and
  `docs/notes/2026-07-13-cc-pty-respawn-crashloop-rootcause.md`.
  """

  require Logger

  @typedoc "A single armed auth-failure observer."
  @type t :: %{name: atom(), match: String.t() | [String.t()] | Regex.t(), fired?: boolean()}

  @doc """
  Per-agent auth-failure topic. Subscribers receive
  `{:pty_auth_failed, agent_uri, observer_name}`.
  """
  @spec topic(URI.t()) :: String.t()
  def topic(%URI{} = agent_uri), do: "pty:auth_failed:" <> URI.to_string(agent_uri)

  @doc """
  The SHARED auth-failure topic (all agents). The domain credential notifier
  (#17 PR-C2) subscribes here ONCE and resolves the owner per event.
  """
  @spec all_topic() :: String.t()
  def all_topic, do: "pty:auth_failed"

  @doc """
  Walk every still-unfired observer against the ANSI-stripped buffer; emit for
  each match and mark it fired (one-shot). Returns the updated observer list.
  The buffer is left intact for the auto-prompt scanner.
  """
  @spec scan([t()], binary(), URI.t()) :: [t()]
  def scan([], _stripped, _agent_uri), do: []

  def scan(observers, stripped, %URI{} = agent_uri) when is_binary(stripped) do
    Enum.map(observers, fn o ->
      if o.fired? or not Ezagent.Domain.Pty.ScreenMatch.matches?(o.match, stripped) do
        o
      else
        fire(o, agent_uri)
        %{o | fired?: true}
      end
    end)
  end

  defp fire(observer, %URI{} = agent_uri) do
    Logger.warning(
      "PtyServer: AUTH FAILURE signal #{observer.name} matched for " <>
        "#{URI.to_string(agent_uri)} — the agent's login is expired/missing; the " <>
        "owner must re-`/login` in its terminal. (no silent mute — #17)"
    )

    :telemetry.execute(
      [:ezagent, :agent, :auth_failed],
      %{count: 1},
      %{agent_uri: agent_uri, observer: observer.name}
    )

    msg = {:pty_auth_failed, agent_uri, observer.name}
    # Per-agent topic (LV badge etc.) + the shared topic (PR-C2 domain notifier).
    Phoenix.PubSub.broadcast(EzagentCore.PubSub, topic(agent_uri), msg)
    Phoenix.PubSub.broadcast(EzagentCore.PubSub, all_topic(), msg)
  end
end
