defmodule Mix.Tasks.Ezagent.Agent.Create do
  @shortdoc "Create a new ESR Agent (cc / echo / curl / future flavor) via unified dispatch"
  @moduledoc """
  Create a new agent via the unified `Behavior.Workspace.:create_agent`
  dispatch path (SPEC `docs/superpowers/specs/2026-05-25-agent-create-cli-gui-parity.md`).

  This task is now a thin wrapper over `Ezagent.Workspace.create_agent/3`
  — the SAME function `EzagentPluginLiveview.AgentNewLive` calls. CLI
  and LV share one code path; cc-flavor agents created via this task
  now have a PTY (the bug the 2026-05-24 audit flagged is fixed).

  ## Usage

      mix ezagent.agent.create entity://agent/<workspace>/<flavor>_<name> \\
          --cwd <dir> \\
          [--with-pty] \\
          [--caps 'kind.behavior,...'] \\
          [--allow-allcaps]

  ## Examples

      # cc-flavor agent in the system workspace
      mix ezagent.agent.create entity://agent/system/cc_demo \\
          --cwd /Users/you/Workspace/my-project \\
          --caps 'chat.send,workspace.read'

      # echo agent without PTY
      mix ezagent.agent.create entity://agent/system/echo_bot

      # echo agent WITH /bin/bash -i sidecar
      mix ezagent.agent.create entity://agent/system/echo_shell \\
          --cwd /tmp/echo-sandbox \\
          --with-pty

      # curl-flavor agent (no cwd, no PTY)
      mix ezagent.agent.create entity://agent/system/curl_api

      # Privileged agent (rare — usually agents have narrow caps)
      mix ezagent.agent.create entity://agent/system/cc_admin \\
          --cwd /tmp \\
          --caps '*' --allow-allcaps

  ## Flags

  - `--cwd <dir>` — working directory. Required for `cc` flavor + for
    `echo` when `--with-pty` is passed. Must exist on the host.
  - `--with-pty` — echo opt-in for a `/bin/bash -i` PTY sidecar.
  - `--caps <str>` — comma-separated cap specs (see
    `Ezagent.Capability.Parser` for grammar). Default empty.
  - `--allow-allcaps` — required if `--caps '*'` (anti-foot-gun).

  ## URI format

  Agent URIs are `entity://agent/<workspace>/<flavor>_<name>` (SPEC v3
  §3 / Phase 9 PR-2). The flavor prefix routes the spawn to the
  correct plugin's Template Class via `Ezagent.AgentFlavorRegistry`.

  ## What this task does NOT do anymore

  Pre-PR (audit `mix ezagent.agent.create` row):
  - Direct `SpawnRegistry.spawn` call (no Template Class, no PTY).
  - Direct `Ezagent.Identity.grant_cap` call (no CapBAC, no audit).
  - `--no-spawn` flag (register without spawn).

  These bypassed dispatch entirely. The unified path:
  - Goes through `Ezagent.Invocation.dispatch/1` (CapBAC, audit, etc.).
  - Always produces a fully-provisioned agent (Kind + PTY for cc).
  - No `--no-spawn` mode (no operator use case post-unification —
    persistence happens as a side effect of the slice mutation).
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:ezagent_core)
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_chat)
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_workspace)

    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [
          caps: :string,
          allow_allcaps: :boolean,
          cwd: :string,
          with_pty: :boolean
        ]
      )

    case positional do
      [agent_uri_str] when is_binary(agent_uri_str) ->
        do_create(agent_uri_str, opts)

      _ ->
        Mix.raise("""
        usage: mix ezagent.agent.create <agent_uri> [--cwd <dir>] [--with-pty] [--caps 'kind.behavior,...'] [--allow-allcaps]

        Example:
          mix ezagent.agent.create entity://agent/system/cc_demo --cwd /tmp --caps 'chat.send,workspace.read'

        Agent URI format: entity://agent/<workspace>/<flavor>_<name>
          where <flavor> is one of cc, echo, curl, np (or any registered flavor)
        """)
    end
  end

  defp do_create(agent_uri_str, opts) do
    caps_str = Keyword.get(opts, :caps, "")
    allow_allcaps = Keyword.get(opts, :allow_allcaps, false)
    cwd = Keyword.get(opts, :cwd, "")
    with_pty? = Keyword.get(opts, :with_pty, false)

    admin_uri = Ezagent.Entity.User.admin_uri()
    admin_caps = Ezagent.Entity.User.admin_caps()
    admin_ctx = %{caller: admin_uri, caps: admin_caps}

    with {:ok, agent_uri} <- parse_uri(agent_uri_str),
         {:ok, workspace_uri, flavor, name} <- decompose(agent_uri),
         :ok <- check_allcaps_flag(caps_str, allow_allcaps),
         {:ok, caps} <- Ezagent.Capability.Parser.parse(caps_str, admin_uri),
         {:ok, %{agent_uri: created_uri, template_name: tmpl_name}} <-
           Ezagent.Workspace.create_agent(
             workspace_uri,
             %{flavor: flavor, name: name, cwd: cwd, with_pty: with_pty?},
             admin_ctx
           ),
         :ok <- Ezagent.Workspace.grant_initial_caps(created_uri, caps, admin_ctx) do
      Mix.shell().info("✓ created #{URI.to_string(created_uri)}")
      if tmpl_name, do: Mix.shell().info("  template: #{tmpl_name}")
      Mix.shell().info("  caps granted: #{length(caps)}")
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
               {:bad_agent_uri, s, "agent entity_name must be <flavor>_<name> (e.g. cc_my-bot)"}}
          end

        _ ->
          {:error, {:bad_uri, s, "expected entity://agent/<workspace>/<flavor>_<name>"}}
      end
    rescue
      e in ArgumentError ->
        {:error, {:bad_uri, s, Exception.message(e)}}
    end
  end

  # Split entity://agent/<workspace>/<flavor>_<name> into the workspace
  # URI + flavor + name (the parts the action body expects in `args`).
  defp decompose(%URI{scheme: "entity", host: "agent", path: "/" <> rest} = _agent_uri) do
    with [workspace_name, entity_name] <- String.split(rest, "/", parts: 2),
         [flavor, name] <- String.split(entity_name, "_", parts: 2) do
      workspace_uri = URI.new!("workspace://#{workspace_name}")
      {:ok, workspace_uri, flavor, name}
    else
      _ -> {:error, {:bad_agent_uri_shape, rest}}
    end
  end

  defp check_allcaps_flag(caps_str, allow_allcaps) do
    if String.contains?(caps_str, "*") and not allow_allcaps do
      {:error, :allcaps_requires_explicit_flag}
    else
      :ok
    end
  end
end
