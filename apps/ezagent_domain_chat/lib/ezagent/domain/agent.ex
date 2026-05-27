defmodule Ezagent.Domain.Agent do
  @moduledoc """
  Flavor-agnostic Agent lifecycle facade. Domain-layer single entry
  point for asking "what's the lifecycle status of this agent?" — UI
  surfaces (`AgentDetailLive`, etc.) call this instead of reaching
  into plugin internals.

  Per `ezagent-developer` skill invariant 8 (plugin authoring
  contract): Domain UI MUST NOT import Plugin module functions. This
  facade is the sanctioned boundary.

  ## Why this lives in `ezagent_domain_chat`

  Domain.Agent is the unifying domain model over the various agent
  flavors (cc, echo, curl, future). The Agent Kind itself lives in
  `Ezagent.Entity.Agent` here in `ezagent_domain_chat`, so the facade
  belongs in the same app. Domain.Agent asks domain primitives, not
  plugin modules. A live `Ezagent.Domain.Pty` sidecar means the agent
  is PTY-backed, regardless of whether the flavor is cc, codex,
  echo-with-pty, or a future plugin.

  ## Domain.Pty PR-A (2026-05-21 SPEC v1)

  Lifecycle now queries `Ezagent.Domain.Pty.alive?/1` instead of
  hardcoding cc as the only PTY-backed flavor. Code.ensure_loaded?
  still guards in case ezagent_domain_pty isn't loaded (test isolation
  contexts); the dep graph makes it always loaded in production builds.

  ## V2 (deferred)

  Per `docs/futures/v2-feedback-log.md` (Architecture gap — No
  auto-trigger from URI registration to associated template
  instantiate): the V2 path is a generic `Ezagent.Behavior.Lifecycle`
  contract carried by every "running" Kind, dispatched via
  `?action=lifecycle.phase`. For V1 the facade derives flavor only for
  display and detects PTY-backed runtime by behavior. The response
  shape is forward-compatible.
  """

  @type phase :: :registered | :instantiated | :alive | :error | :not_found
  @type flavor :: String.t() | nil
  @type status :: %{
          phase: phase(),
          flavor: flavor(),
          detail: map() | nil
        }

  @doc """
  Return the unified lifecycle status of `agent_uri`.

  Returns `%{phase: :not_found, flavor: <derived>, detail: nil}` if
  no Kind is registered at the URI.

  ## Phases

  - `:alive`        — Kind is registered. If a domain sidecar such as
                      PtyServer is running, `detail` carries its status.
  - `:registered`   — reserved for future deeper lifecycle states.
  - `:not_found`    — No KindRegistry entry for the URI.
  - `:instantiated` — (reserved for future use; not emitted by V1
                      pattern-match path).
  - `:error`        — Lifecycle helper raised / returned an error
                      atom while introspecting.
  """
  @spec lifecycle_status(URI.t()) :: status()
  def lifecycle_status(%URI{} = agent_uri) do
    flavor = derive_flavor(agent_uri)

    case Ezagent.KindRegistry.lookup(agent_uri) do
      {:ok, _pid} ->
        delegate_alive_status(flavor, agent_uri)

      :error ->
        %{phase: :not_found, flavor: flavor, detail: nil}
    end
  end

  # ── domain primitive lifecycle detection ─────────────────────────

  defp delegate_alive_status(flavor, agent_uri) do
    try do
      if Code.ensure_loaded?(Ezagent.Domain.Pty) and Ezagent.Domain.Pty.alive?(agent_uri) do
        %{phase: :alive, flavor: flavor, detail: Ezagent.Domain.Pty.status(agent_uri) || %{}}
      else
        %{phase: :alive, flavor: flavor, detail: %{}}
      end
    catch
      _, reason ->
        %{phase: :error, flavor: flavor, detail: %{error: inspect(reason)}}
    end
  end

  # ── subprocess phase facade (PTY-phase-state-machine 2026-05-26
  #    follow-up b codex MED-1 fix) ─────────────────────────────────

  @doc """
  Flavor-aware accessor for the subprocess `:starting | :running |
  :dead` phase introduced in PR-b.

  Routes to:

    * cc → `Ezagent.Domain.Pty.Server.phase/1`
    * np → `Ezagent.Domain.Python.Server.phase/1`
    * other → `:dead` (no subprocess concept)

  Used by `EzagentPluginLiveview.TerminalLive` mount + refresh poll so
  the badge stays consistent across flavors. Without this facade the
  LV's 2s refresh would clobber the np `:python_phase` broadcast with
  a stale cc-only `Pty.Server.phase/1` lookup (codex round-1 MED-1).

  This is the operator-visibility companion to `lifecycle_status/1`:
  the latter is the Kind's lifecycle (`:not_found | :registered |
  :alive`), the former is the subprocess's three-state runtime phase.
  """
  @spec subprocess_phase(URI.t()) :: :starting | :running | :dead
  def subprocess_phase(%URI{} = agent_uri) do
    case derive_flavor(agent_uri) do
      "cc" ->
        if Code.ensure_loaded?(Ezagent.Domain.Pty.Server) do
          Ezagent.Domain.Pty.Server.phase(agent_uri)
        else
          :dead
        end

      "np" ->
        if Code.ensure_loaded?(Ezagent.Domain.Python.Server) do
          Ezagent.Domain.Python.Server.phase(agent_uri)
        else
          :dead
        end

      _other ->
        # Echo / curl / unknown flavor — no subprocess concept; the
        # LV badge falls through to "Unknown" (test handle / non-pty
        # agent). The PubSub subscription is harmless — the topic
        # never receives a broadcast because no Server publishes
        # on a non-cc/non-np agent URI.
        :dead
    end
  end

  # ── flavor derivation ────────────────────────────────────────────

  # Agent URIs are `entity://agent/<workspace>/<flavor>_<name>` per
  # SPEC v3 §3 (3-segment authority) + SPEC v2 §5.14 (flavor lives in
  # name prefix). Workspace URIs / non-agent URIs return nil flavor.
  defp derive_flavor(%URI{scheme: "entity", host: "agent", path: "/" <> rest})
       when rest != "" do
    with [_workspace, entity_name] when entity_name != "" <-
           String.split(rest, "/", parts: 2),
         [flavor, suffix] when flavor != "" and suffix != "" <-
           String.split(entity_name, "_", parts: 2) do
      flavor
    else
      _ -> nil
    end
  end

  defp derive_flavor(_), do: nil
end
