defmodule Ezagent.PluginNp.Template.NpAgent do
  @moduledoc """
  Template Class `np.agent` — declares an NpAgent instance in a Workspace.

  Form fields (auto-derived UI via `Ezagent.UI.Form`):

  - `agent_uri` — `entity://agent/<workspace>/np_<name>` (SPEC v3 §3)
  - `cwd` — working directory for the Python subprocess (optional;
    defaults to `System.tmp_dir!()`). The Python script writes nothing
    persistent — cwd is only relevant for any `import`-relative paths.
  - `timeout_ms` — per-call timeout (optional; default 10s)

  ## On instantiate

  Spawns the NpAgent Kind via the standard Kind spawn path, then starts
  a per-agent `Ezagent.Domain.Python.Server` running the bundled
  `np_compute_server.py` (PEP-723 inline metadata declares
  `numpy + sympy`; `uv run --script` installs them on first run + caches
  for subsequent boots).

  `instantiate/3` returns the 3-element `{:ok, [agent_uri],
  %{fresh?: boolean()}}` form (codex round-6 HIGH-1) — `fresh?` is
  `true` iff THIS call's `DynamicSupervisor.start_child` started the
  Kind worker.

  ## codex round-10 HIGH-2 — partial-spawn teardown

  Mirrors `Ezagent.PluginCc.Template.CcAgent` /
  `Ezagent.PluginEcho.Template.EchoAgent`. If `Ezagent.Kind.spawn/2`
  freshly started the NpAgent Kind and then
  `Ezagent.Domain.Python.start_subprocess/1` fails (uv not on PATH /
  bad script / etc.), the just-started Kind is terminated before the
  error returns — instantiate either fully succeeds or leaves zero
  residue.

  ## Idempotency

  - Kind: `Ezagent.Kind.spawn/2` returns
    `{:error, {:already_started, _}}` → adopted, `fresh?: false`.
  - Python: `Ezagent.Domain.Python.start_subprocess/1` collapses
    concurrent starts atomically at its `:via` Registry — see SPEC
    §3.2 step 2.

  Re-running `instantiate/3` after the agent is fully spawned is a
  no-op (matches `cc.agent.instantiate/3` semantics).
  """

  @behaviour Ezagent.Kind.Template
  @behaviour Ezagent.UI.Form

  require Logger

  alias Ezagent.Domain.Python
  alias Ezagent.Domain.Python.Spec

  @impl Ezagent.Kind.Template
  def template_name, do: "np.agent"

  @impl Ezagent.Kind.Template
  def validate(tmpl) when is_map(tmpl) do
    with :ok <- check_class(tmpl),
         :ok <- check_agent_uri(tmpl),
         :ok <- check_cwd(tmpl),
         :ok <- check_timeout(tmpl) do
      :ok
    end
  end

  def validate(_), do: {:error, :not_a_map}

  defp check_class(%{"class" => "np.agent"}), do: :ok
  defp check_class(%{"class" => other}), do: {:error, {:wrong_class, other}}
  defp check_class(_), do: {:error, :missing_class_field}

  defp check_agent_uri(%{"agent_uri" => uri_str}) when is_binary(uri_str) and uri_str != "" do
    # PR-B unify-uri-query: the URI is an opaque identifier. This validator
    # checks only the structural entity-agent shape; flavor is stored in the
    # Template Class/content, never parsed from the URI name prefix.
    try do
      case Ezagent.URI.new!(uri_str) do
        %URI{scheme: "entity"} = uri ->
          if Ezagent.URI.type?(uri, :agent) do
            :ok
          else
            {:error, {:invalid_agent_uri, uri_str, "agent URI must be an entity agent URI"}}
          end

        %URI{} ->
          {:error, {:invalid_agent_uri, uri_str, "agent URI must be an entity agent URI"}}

        _ ->
          {:error, {:bad_agent_uri, uri_str}}
      end
    rescue
      ArgumentError -> {:error, {:bad_agent_uri, uri_str}}
    end
  end

  defp check_agent_uri(_), do: {:error, :missing_agent_uri}

  defp check_cwd(%{"cwd" => cwd}) when is_binary(cwd) and cwd != "" do
    if File.dir?(cwd), do: :ok, else: {:error, {:bad_cwd, cwd}}
  end

  defp check_cwd(_), do: :ok

  defp check_timeout(%{"timeout_ms" => n}) when is_integer(n) and n > 0, do: :ok

  defp check_timeout(%{"timeout_ms" => s}) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> :ok
      _ -> {:error, {:bad_timeout, s}}
    end
  end

  defp check_timeout(_), do: :ok

  @impl Ezagent.Kind.Template
  def instantiate(_tmpl_name, %{"agent_uri" => agent_uri_str} = tmpl, _workspace_uri) do
    agent_uri = Ezagent.URI.new!(agent_uri_str)

    with :ok <- Ezagent.AgentFlavorAttributes.put_from_template_class(agent_uri, __MODULE__) do
      cwd = Map.get(tmpl, "cwd") || System.tmp_dir!()
      timeout_ms = parse_int(tmpl["timeout_ms"], 10_000)

      init_args = %{
        uri: agent_uri,
        python_handle: agent_uri,
        timeout_ms: timeout_ms,
        # PTY-orphan-restart 2026-05-26 — captured in NpAgent slice so
        # post_init/2 can re-spawn the Python subprocess on demand-spawn
        # / boot races. Same value passed to start_python/2 below.
        cwd: cwd
      }

      case Ezagent.Kind.spawn(Ezagent.Entity.NpAgent, init_args) do
        {:ok, _pid} ->
          # Fresh start — pair the Python subprocess. If it fails, undo
          # the Kind we just started.
          case start_python(agent_uri, cwd) do
            :ok ->
              {:ok, [agent_uri], %{fresh?: true}}

            {:error, reason} ->
              _ = Ezagent.Kind.terminate(agent_uri)
              {:error, {:python_start_failed, reason}}
          end

        {:error, {:already_started, _pid}} ->
          # Adopted — only ensure the Python subprocess is alive, but do
          # NOT undo this branch's work if Python is already running
          # (idempotent re-instantiate).
          #
          # PTY-orphan-restart round-2 (codex finding #4) —
          # `ensure_python_alive/2` now propagates start failures
          # instead of swallowing them. We log + return the error
          # SO the caller (chat domain) gets a real signal. But we do
          # NOT terminate the adopted Kind (it was started by someone
          # else; we don't own its lifecycle on the adopted branch).
          # Returning fresh?:false lets `record_sandbox_state` skip the
          # slice write, preserving the original spawn's state.
          case ensure_python_alive(agent_uri, cwd) do
            :ok ->
              {:ok, [agent_uri], %{fresh?: false}}

            {:error, reason} = err ->
              Logger.error(
                "np.agent: ensure_python_alive failed for adopted Kind " <>
                  "#{URI.to_string(agent_uri)}: #{inspect(reason)}. " <>
                  "Kind remains alive without Python subprocess."
              )

              err
          end

        {:error, reason} ->
          Logger.warning(
            "np.agent Template instantiate failed for #{URI.to_string(agent_uri)}: " <>
              inspect(reason)
          )

          {:error, reason}
      end
    end
  end

  def instantiate(_tmpl_name, tmpl, _workspace_uri), do: {:error, {:invalid_template, tmpl}}

  # --- PTY-orphan-restart 2026-05-26 — Python subprocess respawn callback ---
  #
  # Invoked by `Ezagent.Behavior.NpAgent`'s post_init/2 continuation
  # after the NpAgent Kind has been re-created (fresh OR demand-spawned)
  # in a phx-boot / chat-router scenario where the OS-level Python
  # subprocess is missing. Idempotent: if `Domain.Python.alive?` is
  # true, returns `:ok` without re-spawning.
  #
  # `respawn_data` MUST carry `"cwd"` (binary). Other keys are ignored
  # (np doesn't carry sandbox keys today). The np plugin has no
  # `claude_config_dir` analog — `start_python/2` reads only `cwd` and
  # the pre-bundled `np_compute_server.py` script path.
  @impl Ezagent.Kind.Template
  def ensure_subprocess_alive(%URI{} = agent_uri, respawn_data) when is_map(respawn_data) do
    cond do
      Python.alive?(agent_uri) ->
        :ok

      true ->
        case Map.fetch(respawn_data, "cwd") do
          {:ok, cwd} when is_binary(cwd) and cwd != "" ->
            case start_python(agent_uri, cwd) do
              :ok ->
                Logger.info(
                  "np.agent.ensure_subprocess_alive: respawned Python subprocess for " <>
                    URI.to_string(agent_uri)
                )

                :ok

              {:error, reason} = err ->
                Logger.error(
                  "np.agent.ensure_subprocess_alive: failed to respawn Python for " <>
                    "#{URI.to_string(agent_uri)}: #{inspect(reason)}"
                )

                err
            end

          _ ->
            {:error, {:missing_cwd_in_respawn_data, agent_uri}}
        end
    end
  end

  def ensure_subprocess_alive(_, _), do: {:error, :invalid_args}

  defp start_python(agent_uri, cwd) do
    spec = %Spec{
      handle: agent_uri,
      command: :uv_script,
      script_path: script_path(),
      cwd: cwd,
      env: %{
        "EZAGENT_PYTHON_LIB_DIR" => python_lib_dir(),
        # PTY-orphan-restart 2026-05-26: tag the subprocess with its
        # owning agent URI so `EzagentPluginNp.OrphanReaper` can
        # identify cross-BEAM orphans by env (mirrors cc PtyServer's
        # `EZAGENT_AGENT_URI` convention).
        "EZAGENT_AGENT_URI" => Ezagent.URI.stable_key(agent_uri),
        # PTY-orphan-restart 2026-05-26 round-2 (codex finding #2) —
        # tag with this deployment's identity so the reaper can
        # distinguish "orphan from our prior BEAM run" from "live
        # child of a parallel BEAM" sharing the same OS user. See
        # `Ezagent.DeploymentId`.
        "EZAGENT_DEPLOYMENT_ID" => Ezagent.DeploymentId.deployment_id()
      },
      # uv may need to download numpy + sympy on first run — generous
      # ping timeout for cold cache. Subsequent runs are fast.
      ping_timeout_ms: 120_000,
      # Domain.Python.Server defaults `test_mode` to true under
      # MIX_ENV=test — which makes every RPC return :not_alive so the
      # tier-2 unit tests can stay fast. The np plugin needs the REAL
      # subprocess in test env (the comprehensive 4-agent e2e is the
      # whole point of the plugin), so we override to false. The plugin
      # contract test + Template unit tests do NOT exercise this path —
      # they don't call `instantiate/3` — so the override is e2e-only
      # in practice.
      test_mode: test_mode_override()
    }

    case Python.start_subprocess(spec) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "np.agent: Domain.Python.start_subprocess failed for " <>
            "#{URI.to_string(agent_uri)}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # The Template Class never wants the Domain.Python test_mode short-
  # circuit — np-agent's reason for existing is to validate the REAL
  # Python subprocess. In `:dev` / `:prod` this is nil (default).
  # In `:test` we explicitly force `false` so the e2e gets a real
  # subprocess.
  defp test_mode_override do
    case Mix.env() do
      :test -> false
      _ -> nil
    end
  end

  # PTY-orphan-restart round-2 (codex finding #4) — propagate
  # start_python errors. Previously this discarded the result and
  # returned :ok unconditionally, so a failed-Python adopt path
  # produced an agent that LOOKED alive but had no working subprocess
  # (failures only surfaced on the first user-traffic dispatch).
  defp ensure_python_alive(agent_uri, cwd) do
    if Python.alive?(agent_uri) do
      :ok
    else
      start_python(agent_uri, cwd)
    end
  end

  defp script_path do
    Path.join([:code.priv_dir(:ezagent_plugin_np), "python", "np_compute_server.py"])
  end

  defp python_lib_dir do
    Path.join([:code.priv_dir(:ezagent_domain_python), "python"])
  end

  defp parse_int(nil, default), do: default
  defp parse_int(n, _) when is_integer(n) and n > 0, do: n

  defp parse_int(s, default) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  defp parse_int(_, default), do: default

  # --- Ezagent.UI.Form ---------------------------------------------------

  @impl Ezagent.UI.Form
  def form_fields do
    [
      %{
        name: "agent_uri",
        type: :uri,
        label: "Agent URI",
        required: true,
        placeholder: "np_my-calc"
      },
      %{
        name: "cwd",
        type: :path,
        label: "Working directory (optional; default: system tmp)",
        required: false,
        placeholder: "/tmp/np-sandbox"
      },
      %{
        name: "timeout_ms",
        type: :text,
        label: "Per-call timeout (ms, default 10000)",
        required: false,
        placeholder: "10000"
      }
    ]
  end
end
