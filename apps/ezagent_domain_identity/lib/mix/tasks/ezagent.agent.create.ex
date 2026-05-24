defmodule Mix.Tasks.Ezagent.Agent.Create do
  @shortdoc "Create a new ESR Agent (flavor/_name pattern) with optional caps"
  @moduledoc """
  > **CLI/GUI parity audit 2026-05-24 — Category C (deferred).**
  > Bypasses dispatch AND diverges from the LV path: this task uses
  > `SpawnRegistry.spawn + Identity.grant_cap` (no Template, no
  > PtyServer sidecar) while `agent_new_live.ex` uses
  > `Workspace.add_template + invoke_template_now` (Template + PTY).
  > cc-flavor agents created via THIS task will not have a PTY. The
  > `mix esr agent create` equivalent does NOT exist yet — deleting
  > this task today would lose operator capability. Tracked in
  > `docs/futures/todo.md` § "CLI ↔ GUI parity (audit findings #137
  > still partial)". TODO: per audit Finding 4, register a
  > FacadeRegistry op `(:agent, :create)` that wraps the LV's
  > `Workspace.add_template + invoke_template_now` flow (single code
  > path), then deprecate this task using the PR #302 stub pattern.

  Phase 8c PR-E (Allen 2026-05-20) — provision a new Agent Kind.

  Mirrors `mix ezagent.user.create` but for `entity://agent/<flavor>_<name>`.
  CLI symmetry was missing; Phase 8c PR-G adds the UI surface, this
  task is the equivalent operator-friendly CLI path.

  ## Usage

      mix ezagent.agent.create entity://agent/default/cc_demo \\
          --caps 'chat.send,workspace.read'

      # Spawn immediately into the live KindRegistry (default behavior;
      # use --no-spawn to only persist a snapshot for later boot)
      mix ezagent.agent.create entity://agent/default/echo_bot

  Flags:
  - `--caps <str>` — comma-separated cap specs (see
    `Ezagent.Capability.Parser` for grammar). Default empty.
  - `--allow-allcaps` — required if `--caps '*'`.
  - `--no-spawn` — register the agent in storage but skip live spawn.
    Default is to spawn immediately so the agent appears in
    KindRegistry + can join sessions right away.

  ## URI format

  Agent URIs follow the flavor-prefix convention (PR #149 / SPEC v2 §5.14):
  - `entity://agent/default/cc_<name>` — Claude Code-managed agents
  - `entity://agent/default/echo_<name>` — Echo plugin agents
  - `entity://agent/default/curl_<name>` — Curl-agent plugin (HTTP-API agents)

  The flavor prefix routes the spawn to the correct plugin's
  AgentSupervisor via Ezagent.SpawnRegistry's flavor-resolution
  step (see `EzagentDomainChat.Application.register_spawn_fns/0`).

  ## Behavior

  1. Parses URI + validates flavor-prefix format
  2. Parses caps string via `Ezagent.Capability.Parser`
  3. Spawns the Agent Kind into KindRegistry (unless --no-spawn)
  4. Grants caps via `Ezagent.Identity.grant_cap/3` for each parsed cap
  5. Prints confirmation

  ## Examples

      # Add a cc-orchestrated agent
      mix ezagent.agent.create entity://agent/default/cc_demo --caps 'chat.send'

      # Add an echo bot with no caps (default — purely for testing)
      mix ezagent.agent.create entity://agent/default/echo_test

      # Privileged agent (rare — usually agents have narrow caps)
      mix ezagent.agent.create entity://agent/default/admin_bot --caps '*' --allow-allcaps
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:ezagent_core)
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_chat)

    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [
          caps: :string,
          allow_allcaps: :boolean,
          no_spawn: :boolean
        ]
      )

    case positional do
      [agent_uri_str] when is_binary(agent_uri_str) ->
        do_create(agent_uri_str, opts)

      _ ->
        Mix.raise("""
        usage: mix ezagent.agent.create <agent_uri> [--caps 'kind.behavior,...'] [--allow-allcaps] [--no-spawn]

        Example:
          mix ezagent.agent.create entity://agent/default/cc_demo --caps 'chat.send,workspace.read'

        Agent URI format: entity://agent/<flavor>_<name>
          where <flavor> is one of cc, echo, curl (or any registered flavor)
        """)
    end
  end

  defp do_create(agent_uri_str, opts) do
    caps_str = Keyword.get(opts, :caps, "")
    allow_allcaps = Keyword.get(opts, :allow_allcaps, false)
    spawn? = not Keyword.get(opts, :no_spawn, false)

    with {:ok, agent_uri} <- parse_uri(agent_uri_str),
         :ok <- check_allcaps_flag(caps_str, allow_allcaps),
         {:ok, caps} <-
           Ezagent.Capability.Parser.parse(caps_str, Ezagent.Entity.User.admin_uri()) do
      Mix.shell().info("✓ parsed agent URI: #{URI.to_string(agent_uri)}")
      Mix.shell().info("  caps: #{length(caps)}")

      if spawn?, do: spawn_agent(agent_uri, caps), else: :ok
    else
      {:error, reason} -> Mix.raise("create failed: #{inspect(reason)}")
    end
  end

  defp parse_uri(s) when is_binary(s) do
    # Phase 9 PR-2 (SPEC v3 §3): route through Ezagent.URI.parse!/1
    # so 2-segment URIs are rejected with the SPEC v3 error.
    try do
      uri = Ezagent.URI.parse!(s)

      case uri do
        %URI{scheme: "entity", host: "agent", path: "/" <> rest} ->
          with [_workspace, entity_name] when entity_name != "" <-
                 String.split(rest, "/", parts: 2),
               true <- String.contains?(entity_name, "_") do
            {:ok, uri}
          else
            _ ->
              {:error,
               {:bad_agent_uri, s,
                "agent entity_name must be <flavor>_<name> (e.g. cc_my-bot)"}}
          end

        _ ->
          {:error, {:bad_uri, s, "expected entity://agent/<workspace>/<flavor>_<name>"}}
      end
    rescue
      e in ArgumentError ->
        {:error, {:bad_uri, s, Exception.message(e)}}
    end
  end

  defp check_allcaps_flag(caps_str, allow_allcaps) do
    if String.contains?(caps_str, "*") and not allow_allcaps do
      {:error, :allcaps_requires_explicit_flag}
    else
      :ok
    end
  end

  defp spawn_agent(agent_uri, caps) do
    case Ezagent.SpawnRegistry.spawn(agent_uri) do
      {:ok, _pid} ->
        Mix.shell().info("  spawned live Agent Kind at #{URI.to_string(agent_uri)}")
        grant_caps(agent_uri, caps)

      {:error, reason} ->
        Mix.raise("spawn failed: #{inspect(reason)}")
    end
  end

  defp grant_caps(_agent_uri, []), do: :ok

  defp grant_caps(agent_uri, caps) do
    admin_uri = Ezagent.Entity.User.admin_uri()

    Enum.each(caps, fn cap ->
      case Ezagent.Identity.grant_cap(agent_uri, cap, admin_uri) do
        :ok ->
          Mix.shell().info("  granted: #{inspect(cap)}")

        {:error, reason} ->
          Mix.shell().info("  grant FAILED for #{inspect(cap)}: #{inspect(reason)}")
      end
    end)

    :ok
  end
end
