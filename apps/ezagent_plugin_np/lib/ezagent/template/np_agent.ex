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

  # SPEC v3 §3: entity URIs are 3-segment `/<workspace>/<entity_name>`,
  # flavor lives in the entity_name prefix as `<flavor>_<rest>` per
  # SPEC v2 §5.14. np.agent requires flavor=np.
  defp check_agent_uri(%{"agent_uri" => uri_str}) when is_binary(uri_str) and uri_str != "" do
    case URI.new(uri_str) do
      {:ok, %URI{scheme: "entity", host: "agent", path: "/" <> rest}} when rest != "" ->
        with [_workspace, entity_name] when entity_name != "" <-
               String.split(rest, "/", parts: 2),
             [flavor, suffix] when flavor != "" and suffix != "" <-
               String.split(entity_name, "_", parts: 2) do
          if flavor == "np" do
            :ok
          else
            {:error, {:wrong_agent_flavor, flavor, expected: "np"}}
          end
        else
          _ ->
            {:error,
             {:missing_flavor_prefix, uri_str,
              "agent URIs must be `entity://agent/<workspace>/np_<name>` (SPEC v3 §3)"}}
        end

      {:ok, %URI{scheme: "entity"}} ->
        {:error,
         {:invalid_agent_uri, uri_str,
          "agent URIs must be `entity://agent/<workspace>/np_<name>` (SPEC v3 §3)"}}

      _ ->
        {:error, {:bad_agent_uri, uri_str}}
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
    agent_uri = URI.parse(agent_uri_str)
    cwd = Map.get(tmpl, "cwd") || System.tmp_dir!()
    timeout_ms = parse_int(tmpl["timeout_ms"], 10_000)

    init_args = %{
      uri: agent_uri,
      python_handle: agent_uri,
      timeout_ms: timeout_ms
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
        :ok = ensure_python_alive(agent_uri, cwd)
        {:ok, [agent_uri], %{fresh?: false}}

      {:error, reason} ->
        Logger.warning(
          "np.agent Template instantiate failed for #{URI.to_string(agent_uri)}: " <>
            inspect(reason)
        )

        {:error, reason}
    end
  end

  def instantiate(_tmpl_name, tmpl, _workspace_uri), do: {:error, {:invalid_template, tmpl}}

  defp start_python(agent_uri, cwd) do
    spec = %Spec{
      handle: agent_uri,
      command: :uv_script,
      script_path: script_path(),
      cwd: cwd,
      env: %{
        "EZAGENT_PYTHON_LIB_DIR" => python_lib_dir()
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

  defp ensure_python_alive(agent_uri, cwd) do
    if Python.alive?(agent_uri) do
      :ok
    else
      _ = start_python(agent_uri, cwd)
      :ok
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
        label: "Agent URI (entity://agent/<workspace>/np_<name>)",
        required: true,
        placeholder: "entity://agent/team-alpha/np_my-calc"
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
