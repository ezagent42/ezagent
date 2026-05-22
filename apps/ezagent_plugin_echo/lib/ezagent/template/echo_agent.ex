defmodule Ezagent.PluginEcho.Template.EchoAgent do
  @moduledoc """
  Echo agent Template Class — optionally backed by a local PTY.

  Per Domain.Pty SPEC v1 §4 (cross-flavor opt-in) and §10 row 3 +
  §11 item 6 (deferred PR-D sub-task, now in scope per Allen Feishu
  2026-05-22).

  ## What this Template Class adds

  Before this Template Class, echo agents were created via direct
  `Ezagent.SpawnRegistry.spawn/1` calls (see
  `EzagentPluginEcho.Application` moduledoc — the `default_uri/0`
  bootstrap path). That path remains and is unchanged — the new
  Template Class is **additive**:

  - Without `with_pty: true`: `instantiate/3` just spawns the Echo
    Agent Kind (idempotent, same end-state as the direct spawn path).
  - With `with_pty: true`: ALSO starts a `Ezagent.Domain.Pty.Server`
    running `/bin/bash -i` under erlexec, so the agent shows up in
    the SessionView Terminal tab + is reachable at
    `/identities/agents/:uri/terminal` — the same xterm.js surfaces
    cc agents use.

  This validates the cross-flavor promise of Domain.Pty: PTY is a
  Domain-layer primitive, and any plugin can opt in by spawning a
  Server alongside its Kind. The cc plugin's `Template.CcAgent` does
  the same dance with a richer cmd string; this Template is the
  minimal proof that the contract works for arbitrary plugins.

  ## Template data shape

      %{
        "class" => "echo.agent",
        "agent_uri" => "entity://agent/<workspace>/echo_<name>",
        "with_pty" => true,            # optional, defaults to false
        "cwd" => "/tmp/echo-sandbox"  # required iff with_pty: true
      }

  ## Idempotency

  Both layers are dedup'd:

  - Agent Kind via `KindRegistry` — `SpawnRegistry.spawn/1` returns
    `{:error, {:already_started, _}}` for duplicates; we treat that
    as success.
  - PtyServer via the Domain.Pty :via Registry — concurrent starts
    collapse to the same pid; `Ezagent.Domain.Pty.start/2` returns
    the same `{:error, {:already_started, _}}` shape.

  Re-running `instantiate/3` after the agent is fully spawned is a
  no-op (matches `cc.agent.instantiate/3` semantics).

  ## Cap shape

  Unchanged from non-templated echo agents created via direct
  `SpawnRegistry.spawn/1`:

  - `kind: :agent`
  - `behavior: Ezagent.Behavior.Echo` (the echo plugin's
    Application registers `:say` + `:receive` actions at boot)
  - `instance: entity://agent/<workspace>/echo_<name>` or `:any`

  ## Backward compat

  The default echo agent (`entity://agent/default/echo_default`)
  continues to be spawned post-boot by the chat plugin via
  `Ezagent.SpawnRegistry.spawn/1` (see `EzagentPluginEcho.Application`
  PR-M notes). This Template Class is purely an additional creation
  path; nothing in the existing echo runtime breaks if it's never
  used.
  """

  @behaviour Ezagent.Kind.Template
  @behaviour Ezagent.UI.Form

  require Logger

  @impl Ezagent.Kind.Template
  def template_name, do: "echo.agent"

  @impl Ezagent.Kind.Template
  def validate(tmpl) when is_map(tmpl) do
    with :ok <- check_class(tmpl),
         :ok <- check_agent_uri(tmpl),
         :ok <- check_pty_cwd(tmpl) do
      :ok
    end
  end

  def validate(_), do: {:error, :not_a_map}

  defp check_class(%{"class" => "echo.agent"}), do: :ok
  defp check_class(%{"class" => other}), do: {:error, {:wrong_class, other}}
  defp check_class(_), do: {:error, :missing_class_field}

  # Mirrors `Ezagent.PluginCc.Template.CcAgent.check_agent_uri/1` shape
  # (Phase 9 PR-2 / SPEC v3 §3) — entity URIs are 3-segment
  # `/<workspace>/<entity_name>`, flavor lives in the entity_name
  # prefix as `<flavor>_<rest>` (SPEC v2 §5.14). echo.agent requires
  # flavor=echo.
  defp check_agent_uri(%{"agent_uri" => uri_str}) when is_binary(uri_str) and uri_str != "" do
    case URI.new(uri_str) do
      {:ok, %URI{scheme: "entity", host: "agent", path: "/" <> rest}} when rest != "" ->
        with [_workspace, entity_name] when entity_name != "" <-
               String.split(rest, "/", parts: 2),
             [flavor, suffix] when flavor != "" and suffix != "" <-
               String.split(entity_name, "_", parts: 2) do
          if flavor == "echo" do
            :ok
          else
            {:error, {:wrong_agent_flavor, flavor, expected: "echo"}}
          end
        else
          _ ->
            {:error,
             {:missing_flavor_prefix, uri_str,
              "agent URIs must be `entity://agent/<workspace>/echo_<name>` (Phase 9 PR-2)"}}
        end

      {:ok, %URI{scheme: "entity"}} ->
        {:error,
         {:invalid_agent_uri, uri_str,
          "agent URIs must be `entity://agent/<workspace>/echo_<name>` (Phase 9 PR-2)"}}

      _ ->
        {:error, {:bad_agent_uri, uri_str}}
    end
  end

  defp check_agent_uri(_), do: {:error, :missing_agent_uri}

  # `cwd` is required ONLY when the operator opts into PTY. Without
  # PTY the echo agent has no filesystem context (it's a pure
  # dispatch echo) so cwd is irrelevant.
  defp check_pty_cwd(%{"with_pty" => true, "cwd" => cwd})
       when is_binary(cwd) and cwd != "",
       do: :ok

  defp check_pty_cwd(%{"with_pty" => true}), do: {:error, :cwd_required_when_with_pty}
  defp check_pty_cwd(_), do: :ok

  @impl Ezagent.Kind.Template
  def instantiate(_tmpl_name, %{"agent_uri" => uri_str} = tmpl, _workspace_uri) do
    agent_uri = URI.parse(uri_str)

    # codex round-6 HIGH-1 — the 3-element `{:ok, uris, %{fresh?: _}}`
    # return carries whether THIS call STARTED the Agent Kind worker.
    # The idempotency short-circuit means the worker pre-existed →
    # `fresh?: false`.
    cond do
      agent_kind_alive?(agent_uri) and pty_ok?(tmpl, agent_uri) ->
        {:ok, [agent_uri], %{fresh?: false}}

      true ->
        with {:ok, started_or_adopted} <- ensure_agent_kind(agent_uri),
             :ok <- maybe_start_pty(tmpl, agent_uri) do
          {:ok, [agent_uri], %{fresh?: started_or_adopted == :started}}
        end
    end
  end

  def instantiate(_tmpl_name, tmpl, _workspace_uri),
    do: {:error, {:invalid_template, tmpl}}

  # codex round-6 HIGH-1 — `SpawnRegistry.spawn_detailed/1` preserves
  # the atomic `DynamicSupervisor` outcome (`:started` vs
  # `:already_started`) — the ground-truth freshness signal, not a
  # TOCTOU-prone pre-probe. Returns `{:ok, :started | :already_started}`.
  defp ensure_agent_kind(agent_uri) do
    case Ezagent.SpawnRegistry.spawn_detailed(agent_uri) do
      {:ok, :started, _pid} ->
        {:ok, :started}

      {:ok, :already_started, _pid} ->
        # Atomic dedup at KindRegistry level — same pattern as
        # `cc.agent.instantiate/3`. Still a success, but THIS call did
        # not create the worker.
        {:ok, :already_started}

      {:error, reason} ->
        Logger.warning(
          "echo.agent: SpawnRegistry.spawn_detailed failed for #{URI.to_string(agent_uri)}: " <>
            inspect(reason)
        )

        {:error, {:agent_spawn_failed, reason}}
    end
  end

  # PTY opt-in: when `with_pty: true`, start a Server running
  # `/bin/bash -i` in the requested cwd. In `:test` env the Server
  # short-circuits `:exec.run/2` via `test_mode: true` (default when
  # `Mix.env() == :test`); the supervisor/registry plumbing is still
  # exercised, so invariants like `Domain.Pty.alive?/1` return true.
  defp maybe_start_pty(%{"with_pty" => true, "cwd" => cwd}, agent_uri)
       when is_binary(cwd) and cwd != "" do
    params =
      case Mix.env() do
        :test -> %{cwd: cwd, test_mode: true}
        _ -> %{cwd: cwd, cmd_override: "/bin/bash -i"}
      end

    case Ezagent.Domain.Pty.start(agent_uri, params) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "echo.agent: PtyServer start failed for #{URI.to_string(agent_uri)}: " <>
            inspect(reason)
        )

        {:error, {:pty_start_failed, reason}}
    end
  end

  defp maybe_start_pty(_tmpl, _agent_uri), do: :ok

  defp agent_kind_alive?(agent_uri) do
    case Ezagent.KindRegistry.lookup(agent_uri) do
      {:ok, _pid} -> true
      :error -> false
    end
  end

  # If the template asks for PTY, idempotency requires checking the
  # PtyServer is alive too — otherwise re-instantiate after a PTY
  # crash would silently skip restart. Without PTY, the Kind being
  # alive is enough.
  defp pty_ok?(%{"with_pty" => true}, agent_uri), do: Ezagent.Domain.Pty.alive?(agent_uri)
  defp pty_ok?(_tmpl, _agent_uri), do: true

  # --- Ezagent.UI.Form ------------------------------------------------

  @impl Ezagent.UI.Form
  def form_fields do
    [
      %{
        name: "agent_uri",
        type: :uri,
        label: "Agent URI (entity://agent/<workspace>/echo_<name>)",
        required: true,
        placeholder: "entity://agent/default/echo_my-bot"
      },
      %{
        name: "with_pty",
        type: :boolean,
        label: "With local PTY (runs /bin/bash -i)",
        required: false,
        default: "false"
      },
      %{
        name: "cwd",
        type: :path,
        label: "Working directory (required if With PTY)",
        required: false,
        placeholder: "/tmp/echo-sandbox"
      }
    ]
  end
end
