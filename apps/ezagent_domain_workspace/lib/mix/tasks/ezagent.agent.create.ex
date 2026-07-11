defmodule Mix.Tasks.Ezagent.Agent.Create do
  @shortdoc "Create a new Ezagent Agent (cc / py / curl / future flavor) via unified dispatch"
  @moduledoc """
  Create a new agent via the unified `Behavior.Workspace.:create_agent`
  dispatch path (SPEC `docs/superpowers/specs/2026-05-25-agent-create-cli-gui-parity.md`).

  This task is now a thin wrapper over `Ezagent.Workspace.create_agent/3` — the
  SAME function the operator UI calls. CLI and UI share one code path; cc-flavor
  agents created via this task now have a PTY (the bug the 2026-05-24 audit
  flagged is fixed).

  ## Usage

      mix ezagent.agent.create entity://agent/<workspace>/<name> \\
          --flavor <flavor> \\
          --cwd <dir> \\
          [--with-pty] \\
          [--from <source-agent-uri>] \\
          [--caps 'kind.behavior,...'] \\
          [--allow-allcaps]

  ## Examples

      # cc-flavor agent in the system workspace
      mix ezagent.agent.create entity://agent/system/demo \\
          --flavor cc \\
          --cwd /Users/you/Workspace/my-project \\
          --caps 'chat.send,workspace.read'

      # py agent (operator-supplied python script; no cwd, no PTY)
      mix ezagent.agent.create entity://agent/system/bot --flavor py

      # curl-flavor agent (no cwd, no PTY)
      mix ezagent.agent.create entity://agent/system/api --flavor curl

      # Privileged agent (rare — usually agents have narrow caps)
      mix ezagent.agent.create entity://agent/system/admin \\
          --flavor cc \\
          --cwd /tmp \\
          --caps '*' --allow-allcaps

      # Clone an existing cc agent's config_dir into a new agent
      # (deep-copy of source's per-agent CLAUDE_CONFIG_DIR — credentials,
      # settings, installed plugins). Chat history is NOT carried over;
      # the new agent starts with a fresh chat slice.
      mix ezagent.agent.create entity://agent/system/user-alice \\
          --flavor cc \\
          --from entity://agent/system/cc_linyilun-default \\
          --cwd /tmp/alice-cwd

  ## Flags

  - `--flavor <flavor>` — required stored agent flavor (cc, py, curl, np, or any registered flavor).
  - `--cwd <dir>` — working directory. Required for `cc` / `codex`
    flavors. Must exist on the host.
  - `--with-pty` — cc opt-in for a `/bin/bash -i` PTY sidecar.
  - `--from <uri>` — clone source agent's per-agent config_dir
    (the CLAUDE_CONFIG_DIR contents — credentials, settings, plugins)
    into the new agent. Only `cc` flavor; the source must be a `cc`
    agent the caller has `sandbox.read` cap on (else
    `{:error, :source_not_readable}`). Deep filesystem copy; chat
    history is NOT carried (the new agent's chat slice starts fresh).
  - `--caps <str>` — comma-separated cap specs (see
    `Ezagent.Capability.Parser` for grammar). Default empty.
  - `--allow-allcaps` — required if `--caps '*'` (anti-foot-gun).

  ## URI format

  Agent URIs are `entity://agent/<workspace>/<name>`. Flavor is a
  stored attribute supplied by `--flavor` and routed through
  `Ezagent.AgentFlavorRegistry`.

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

  @operator_store_timeout_ms 5_000

  @impl Mix.Task
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:ezagent_core)
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_session)
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_workspace)

    # Boot every flavor plugin we know about so AgentFlavorRegistry
    # populates. Without this the action body's `validate_flavor/1`
    # only sees `cc` (chat domain's flavor) and rejects py / curl with
    # `{:bad_flavor, _}`. Each `ensure_all_started/1` is a no-op if the
    # app is missing from this build so the task degrades to whatever
    # plugins are compiled in. (py-agent P4: `np` is now a py-ROLE — its
    # role recipe rides `ezagent_plugin_py`'s boot, no separate plugin.)
    for plugin <- [
          :ezagent_plugin_cc,
          :ezagent_plugin_py,
          :ezagent_plugin_curl_agent
        ] do
      _ = Application.ensure_all_started(plugin)
    end

    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [
          caps: :string,
          allow_allcaps: :boolean,
          flavor: :string,
          cwd: :string,
          with_pty: :boolean,
          from: :string
        ]
      )

    case positional do
      [agent_uri_str] when is_binary(agent_uri_str) ->
        do_create(agent_uri_str, opts)

      _ ->
        Mix.raise("""
        usage: mix ezagent.agent.create <agent_uri> --flavor <flavor> [--cwd <dir>] [--with-pty] [--from <source-uri>] [--caps 'kind.behavior,...'] [--allow-allcaps]

        Example:
          mix ezagent.agent.create <agent-uri> --flavor cc --cwd /tmp --caps 'chat.send,workspace.read'

        Clone an existing cc agent's config_dir:
          mix ezagent.agent.create <agent-uri> --flavor cc --from <source-agent-uri> --cwd /tmp/alice

        Agent URI: an entity agent URI built by Ezagent.URI.agent/2
          where --flavor is one of cc, py, curl, np (or any registered flavor)
        """)
    end
  end

  defp do_create(agent_uri_str, opts) do
    caps_str = Keyword.get(opts, :caps, "")
    allow_allcaps = Keyword.get(opts, :allow_allcaps, false)
    cwd = Keyword.get(opts, :cwd, "")
    with_pty? = Keyword.get(opts, :with_pty, false)
    from_str = Keyword.get(opts, :from)
    flavor = opts |> Keyword.get(:flavor, "") |> to_string() |> String.trim()

    # System-principal elimination (#154, 2026-06-19) — the operator mix task
    # runs under the real genesis admin entity `User.admin_uri()`, NOT the
    # eliminated `system://mix-task` ambient wildcard (shell access = admin
    # authority, in-VM trust §10.5). `admin_ctx` is used on TWO sub-paths with
    # DIFFERENT authorization mechanics:
    #
    #   * `Workspace.create_agent/3` — a NON-grant dispatch authorized by
    #     `ctx.caps` at step 5.5. It carries an INLINE
    #     `cap(:workspace, Workspace, :create_agent)` scoped to the target
    #     workspace; `granted_by` = `admin_uri` (provenance only on an inline
    #     authorizer, never used as ISSUE authority).
    #
    #   * `Workspace.issue_and_absorb_initial_caps/3` — an ISSUE path using
    #     `{:held_by, ctx.caller}`. `Ezagent.Cap.issue/3` RE-READS the caller's
    #     REAL held caps
    #     (`Ezagent.Identity.read_held_caps/1`) to authorize, so `caller` MUST
    #     be `admin_uri` — the admin User Kind is seeded with the bootstrap
    #     wildcard (`User.initial_caps_for_spawn/1`), which authorizes granting
    #     the operator-parsed caps. (The prior `caller: mix-task` here was a
    #     latent bug — `read_held_caps` on a `system://` URI returns empty, so
    #     any `--caps` grant would have failed; it only ever short-circuited
    #     because the empty-caps clause returns `:ok` when no `--caps` given.)
    #     The inline `ctx.caps` is moot on this sub-path.
    admin_uri = Ezagent.Entity.User.admin_uri()

    with {:ok, agent_uri} <- parse_uri(agent_uri_str),
         :ok <- require_flavor(flavor),
         {:ok, workspace_uri, name} <- decompose(agent_uri),
         admin_ctx = operator_admin_ctx(admin_uri, workspace_uri),
         {:ok, from_uri} <- parse_from(from_str),
         :ok <- check_allcaps_flag(caps_str, allow_allcaps),
         {:ok, caps} <- Ezagent.Capability.Parser.parse(caps_str, admin_uri),
         create_args =
           build_create_args(%{
             flavor: flavor,
             name: name,
             cwd: cwd,
             with_pty: with_pty?,
             from: from_uri
           }),
         {:ok, %{agent_uri: created_uri, template_name: tmpl_name}} <-
           Ezagent.Workspace.create_agent(workspace_uri, create_args, admin_ctx),
         {:ok, issued_caps} <-
           Ezagent.Workspace.issue_and_absorb_initial_caps(created_uri, caps, admin_ctx),
         :ok <-
           Ezagent.Identity.CapAbsorbAwait.await_exact(
             created_uri,
             issued_caps,
             @operator_store_timeout_ms
           ) do
      Mix.shell().info("✓ created #{URI.to_string(created_uri)}")
      if tmpl_name, do: Mix.shell().info("  template: #{tmpl_name}")
      if from_uri, do: Mix.shell().info("  cloned from: #{URI.to_string(from_uri)}")
      Mix.shell().info("  caps granted: #{length(caps)}")
    else
      {:error, reason} -> Mix.raise("create failed: #{inspect(reason)}")
    end
  end

  # System-principal elimination (#154, 2026-06-19) — the operator → admin
  # entity ctx for the `create_agent` NON-grant dispatch (replaces the
  # eliminated `system://mix-task` ambient wildcard). `caller` = `admin_uri`
  # (a real entity, also the `{:held_by}` actor `Cap.issue/3` re-reads on the
  # downstream initial-cap ISSUE sub-path); `caps` carries the INLINE
  # `cap(:workspace, Workspace, :create_agent)` scoped to the target workspace
  # (the step-5.5 authorizer), `granted_by` = `admin_uri` (provenance only on
  # an inline authorizer never used as ISSUE authority).
  defp operator_admin_ctx(%URI{} = admin_uri, %URI{scheme: "workspace"} = workspace_uri) do
    %{
      caller: admin_uri,
      caps: [
        %Ezagent.Capability{
          Ezagent.Capability.cap(
            :workspace,
            Ezagent.ActionSet.Workspace,
            :create_agent,
            Ezagent.URI.instance(workspace_uri),
            Ezagent.Capability.workspace_of(workspace_uri)
          )
          | granted_by: admin_uri,
            granted_at: DateTime.utc_now()
        }
      ]
    }
  end

  # `--from` is optional. When omitted → no `:from` key in args.
  # When present, parse as an entity agent URI; the
  # action body handles cap-check + source resolution.
  defp parse_from(nil), do: {:ok, nil}

  defp parse_from(s) when is_binary(s) do
    case parse_uri(s) do
      {:ok, uri} -> {:ok, uri}
      {:error, reason} -> {:error, {:bad_from_uri, reason}}
    end
  end

  defp build_create_args(%{from: nil} = base), do: Map.delete(base, :from)
  defp build_create_args(base), do: base

  defp parse_uri(s) when is_binary(s) do
    # Phase 9 PR-2 (SPEC v3 §3): route through Ezagent.URI.new!/1
    # so 2-segment URIs are rejected with the SPEC v3 error.
    try do
      uri = Ezagent.URI.new!(s)

      case uri do
        %URI{scheme: "entity"} ->
          with {:ok, "agent"} <- Ezagent.URI.type(uri),
               {:ok, _workspace_name} <- Ezagent.URI.workspace_name(uri),
               {:ok, entity_name} when entity_name != "" <- Ezagent.URI.name(uri) do
            {:ok, uri}
          else
            _ ->
              {:error, {:bad_agent_uri, s, "expected entity agent URI"}}
          end

        _ ->
          {:error, {:bad_uri, s, "expected entity agent URI"}}
      end
    rescue
      e in ArgumentError ->
        {:error, {:bad_uri, s, Exception.message(e)}}
    end
  end

  defp require_flavor(flavor) when is_binary(flavor) and flavor != "", do: :ok
  defp require_flavor(_), do: {:error, :flavor_required}

  # Split entity://agent/<workspace>/<name> into the workspace URI +
  # opaque name. Flavor comes from `--flavor`.
  defp decompose(%URI{scheme: "entity"} = agent_uri) do
    with {:ok, "agent"} <- Ezagent.URI.type(agent_uri),
         {:ok, workspace_name} <- Ezagent.URI.workspace_name(agent_uri),
         {:ok, name} when name != "" <- Ezagent.URI.name(agent_uri) do
      workspace_uri = Ezagent.URI.workspace(workspace_name)
      {:ok, workspace_uri, name}
    else
      _ -> {:error, {:bad_agent_uri_shape, URI.to_string(agent_uri)}}
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
