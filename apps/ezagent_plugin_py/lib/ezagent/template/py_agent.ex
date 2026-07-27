defmodule Ezagent.Template.PyAgent do
  @moduledoc """
  Template Class `py.agent` — declares a PyAgent instance in a Workspace, on
  the CANONICAL config_dir seam.

  ## The create-time script file-channel (spec §0.2 P1 — the CORE deliverable)

  py is a GENERAL flavor: its per-message logic is an OPERATOR-SUPPLIED python
  script. The script flows in as the template `script` config; `instantiate/3`
  WRITES it into the agent's per-agent `config_dir` (the domain-allocated
  `"allocated_config_dir"`) as `agent.py`, then starts the per-agent
  `Ezagent.Domain.Python` subprocess pointing at that installed file. This is
  the RF-5b *shape* scoped to one flavor's create route — operator script →
  this agent's config_dir, at create.

  ## Canonical seam — `provision_and_instantiate` + `"config_dir"` reference

  This Template declares `config_dir_namespace/0 → "py"`. The persisted
  template carries a `"config_dir"` REFERENCE (set by the create route), which
  drives `Ezagent.Kind.Template.maybe_allocate_config_dir/2` to allocate
  `<Home>/py-agents/<ws>/<name>/` and inject it back as
  `"allocated_config_dir"` BEFORE `instantiate/3`. py rides this single seam —
  it does NOT hand-roll allocation.

  ## A NEW shape: non-credentialled YET config-dir-allocating

  cc/codex are credentialled (their Template implements
  `Ezagent.Agent.CredentialAdapter`) and route through the #17 credential
  cascade (`spawn_file_flavor_via_cascade`). echo/np are non-credentialled but
  allocate NO config_dir. py is the first NON-credentialled flavor that DOES
  allocate a config_dir: it stays on the non-cascade Loader path
  (`Workspace.Loader.invoke_template` → `provision_and_instantiate`) yet
  carries a `"config_dir"` reference so the dir is allocated. It MUST NOT be a
  `CredentialAdapter` (would mis-route through the cascade).

  ## Script immutability (spec §5 — the injection gate, Task 1.5b)

  The script is set ONCE at create. `install_script/2` writes `agent.py` only
  if it is absent OR byte-identical to the requested content; a DIFFERING
  content (a post-create template-edit / re-instantiate that would overwrite
  the installed script) is REFUSED with `{:error, :script_immutable}`. The
  authoring authority is the create-cap (`:create_agent` on the workspace),
  which a re-instantiate cannot smuggle past — overwriting the script requires
  going through create. `configure`/`reset` are BEAM-side `{:set}` effects that
  never touch the script.
  """

  @behaviour Ezagent.Kind.Template
  @behaviour Ezagent.UI.Form

  alias Ezagent.Domain.Python.{AgentLifecycle, Spec}

  @default_timeout_ms 10_000
  @script_filename "agent.py"

  @impl Ezagent.Kind.Template
  def template_name, do: "py.agent"

  # Config schema consumed by the unified create path's FlavorConfig.coerce/2
  # (the operator `script` + optional `timeout_ms` flow through `flavor_config`).
  @impl Ezagent.Kind.Template
  def config_schema do
    [
      %{key: "script", type: :text, label: "Python script (operator-authored)", required: true},
      %{key: "timeout_ms", type: :text, label: "Per-call timeout (ms)", required: false}
    ]
  end

  # PR-3 (domain.agent D2) — py's config_dir namespace. Drives the allocated
  # TARGET `<Home>/py-agents/<ws>/<name>/`.
  @impl Ezagent.Kind.Template
  def config_dir_namespace, do: "py"

  @impl Ezagent.Kind.Template
  def validate(tmpl) when is_map(tmpl) do
    with :ok <- check_class(tmpl),
         :ok <- check_agent_uri(tmpl),
         :ok <- check_script(tmpl),
         :ok <- check_timeout(tmpl) do
      :ok
    end
  end

  def validate(_), do: {:error, :not_a_map}

  defp check_class(%{"class" => "py.agent"}), do: :ok
  defp check_class(%{"class" => other}), do: {:error, {:wrong_class, other}}
  defp check_class(_), do: {:error, :missing_class_field}

  defp check_agent_uri(tmpl), do: Ezagent.Kind.Template.check_agent_uri(tmpl)

  defp check_script(%{"script" => s}) when is_binary(s) and s != "", do: :ok
  defp check_script(_), do: {:error, :missing_script}

  defp check_timeout(%{"timeout_ms" => n}) when is_integer(n) and n > 0, do: :ok

  defp check_timeout(%{"timeout_ms" => s}) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> :ok
      _ -> {:error, {:bad_timeout, s}}
    end
  end

  defp check_timeout(_), do: :ok

  # --- instantiate/3 — install the script + start the subprocess -----------
  #
  # Reads the domain-allocated `"allocated_config_dir"` (the canonical seam
  # injected it from the `"config_dir"` reference), writes the operator script
  # to `<dir>/agent.py`, spawns the PyAgent Kind, then starts the subprocess.
  @impl Ezagent.Kind.Template
  def instantiate(_tmpl_name, %{"agent_uri" => agent_uri_str} = tmpl, _workspace_uri) do
    instantiate_with_opts(agent_uri_str, tmpl, [])
  end

  def instantiate(_tmpl_name, tmpl, _workspace_uri), do: {:error, {:invalid_template, tmpl}}

  @impl Ezagent.Kind.Template
  def instantiate(_tmpl_name, %{"agent_uri" => agent_uri_str} = tmpl, _workspace_uri,
        launch_context: launch_context
      ) do
    instantiate_with_opts(agent_uri_str, tmpl, launch_context: launch_context)
  end

  def instantiate(_tmpl_name, _tmpl, _workspace_uri, _opts), do: {:error, :invalid_launch_options}

  defp instantiate_with_opts(agent_uri_str, tmpl, opts) do
    agent_uri = Ezagent.URI.new!(agent_uri_str)

    with {:ok, config_dir} <- fetch_config_dir(tmpl),
         {:ok, script} <- fetch_script(tmpl),
         :ok <- Ezagent.AgentFlavorAttributes.put_from_template_class(agent_uri, __MODULE__),
         {:ok, script_path} <- install_script(config_dir, script) do
      timeout_ms = parse_int(Map.get(tmpl, "timeout_ms"), @default_timeout_ms)

      init_args = %{
        uri: agent_uri,
        python_handle: agent_uri,
        script_path: script_path,
        cwd: config_dir,
        timeout_ms: timeout_ms,
        # P4b — py folds onto the unified Entity.Agent Kind. The Loader/seed
        # path spawns directly (no unified-create instance_behaviors threading),
        # so set the per-instance behavior SET explicitly: base Agent set +
        # Behavior.PyAgent (the :py_sync_result / :py_reset / :py_configure
        # handlers). Without this the instance captures only the base set and
        # the re-dispatched :py_sync_result has no handler (no reply).
        behaviors: Ezagent.Entity.Agent.base_behaviors() ++ [Ezagent.ActionSet.PyAgent],
        # P4b — DURABLE flavor record (cc/codex precedent). py now routes inbound
        # chat through AgentBridge, which resolves the agent's flavor to pick the
        # `:in_process_sync` transport. ETS `AgentFlavorAttributes` is volatile;
        # persisting `template_class` into the `:sandbox` slice lets
        # `AgentFlavorResolver.resolve_flavor_from_sandbox/1` recover flavor "py"
        # after a BEAM cold restart — else a workspace py agent self-heals its
        # subprocess but silently never replies (delivery mis-routes to
        # :subprocess_ws). codex-review B1.
        template_class: __MODULE__
      }

      # FIRE-AND-FORGET provision (2026-07-06 go-live "fix Ⓑ"). The Python
      # subprocess is brought up ASYNCHRONOUSLY by
      # `Ezagent.ActionSet.PyAgent.activate/2` — the documented unified start
      # hook that reads the durable `state.script_path` + `state.cwd` (`create/1`
      # persists them from these same `init_args`) and self-heals the subprocess
      # OFF the hot path. It MUST NOT be started synchronously here: a cold
      # `uv run` provision (~9.6s for a first-run numpy/sympy recipe on a fresh
      # container) blocks `Domain.Python.start_subprocess`'s `await_ready` ping,
      # and this `instantiate/3` runs INSIDE the Workspace `create_session`
      # GenServer call — so the session create (and every other create queued
      # behind the single Workspace Kind) timed out at the 5s dispatch budget
      # after ANY redeploy replaced the container. The Kind is materialized +
      # registered + joinable the instant `Kind.spawn` returns; first `:cast`
      # messages buffer via `PendingDelivery` until the subprocess flips
      # `:ready`. A `:uv_not_found` / cold-provision failure now surfaces in
      # `activate/2` (which keeps the Kind alive in a DEGRADED, no-subprocess
      # state, records the durable `:last_error {:provision_failed, _}` marker,
      # and FAIL-LOUD-AT-USE via the next `:receive` → `:not_alive`).
      #
      # PR #1259 codex review item 1b — the ADOPT arm (`:already_started`) must
      # not report success over a ZOMBIE: if the adopted agent's subprocess is
      # dead (a prior provision failed), RETRY the provision — asynchronously
      # (a fire-and-forget `:py_ensure_alive` cast into the agent's own Kind),
      # never blocking this create path. When the underlying failure has
      # cleared (network back, uv installed), the retry recovers the member
      # and clears the `:last_error` marker.
      # derivation-edge: template-post-obligation TemplateSpawn records fresh workers
      # #201 PR-1 — the spawn receipt surfaces BOTH the atomic winner verdict
      # (`:started` / `:already_started`) and the core logical-create verdict
      # (`created?`), which the TemplateSpawn chokepoint gates create-only
      # writes on.
      case Ezagent.Kind.spawn_receipt(Ezagent.Entity.Agent, init_args, opts) do
        {:ok, :started, _pid, %{created?: created?}} ->
          {:ok, [agent_uri], %{fresh?: true, created?: created?, config_dir_path: config_dir}}

        {:ok, :already_started, _pid, _receipt} ->
          _ = async_reensure_if_dead(agent_uri)
          {:ok, [agent_uri], %{fresh?: false, config_dir_path: config_dir}}

        {:error, {:already_registered, _}} ->
          # Same adopt case surfaced through the KindRegistry race arm (the
          # cc/SessionCreator spawn paths handle both shapes; py previously
          # only matched `:already_started` and ERRORED an idempotent adopt).
          _ = async_reensure_if_dead(agent_uri)
          {:ok, [agent_uri], %{fresh?: false, config_dir_path: config_dir}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Adopt-path zombie guard (PR #1259 item 1b). `Domain.Python.alive?/1` is a
  # cheap Registry lookup; when the subprocess is dead, dispatch the agent's
  # own `:py_ensure_alive` as a fire-and-forget `:cast` so the provision retry
  # runs in the AGENT's process, off the creator's path. A cast landing while
  # the agent is still `:not_ready` (first provision still running) buffers via
  # PendingDelivery and drains after — a harmless idempotent re-check.
  #
  # The retry is presented by the agent, but the artifact is born signed by
  # the concrete Agent Kind through K.grant. Reviewed framework code may ask
  # the target authority for this one-shot cap; it must never construct an
  # inline unsigned/self-stamped artifact.
  defp async_reensure_if_dead(%URI{} = agent_uri) do
    if Ezagent.Domain.Python.alive?(agent_uri) do
      :ok
    else
      target = Ezagent.URI.new!("#{URI.to_string(agent_uri)}?action=py_agent.py_ensure_alive")

      admin = apply(Module.concat([Ezagent, Entity, User]), :admin_uri, [])

      with {:ok, signed_cap} <-
             Ezagent.Cap.issue_for_action({:admin, admin}, agent_uri, target) do
        _ =
          Ezagent.Invocation.dispatch(%Ezagent.Invocation{
            target: target,
            mode: :cast,
            args: %{},
            ctx: %{
              caller: agent_uri,
              authenticated_principal: agent_uri,
              caps: MapSet.new([signed_cap]),
              reply: :ignore
            },
            origin: :trusted_internal
          })
      end

      :ok
    end
  end

  # The domain MUST have allocated the config_dir (the template carries a
  # `"config_dir"` reference → `provision_and_instantiate` injected
  # `"allocated_config_dir"`). Missing it = the create route didn't carry the
  # reference — fail loud rather than silently writing to a bogus path.
  defp fetch_config_dir(tmpl) do
    case Map.get(tmpl, "allocated_config_dir") do
      dir when is_binary(dir) and dir != "" -> {:ok, dir}
      _ -> {:error, :missing_allocated_config_dir}
    end
  end

  defp fetch_script(tmpl) do
    case Map.get(tmpl, "script") do
      s when is_binary(s) and s != "" -> {:ok, s}
      _ -> {:error, :missing_script}
    end
  end

  # --- the injection gate (Task 1.5b) --------------------------------------
  #
  # Write `agent.py` once. A repeated install with byte-IDENTICAL content is a
  # no-op (idempotent re-instantiate / cold restart). A DIFFERING content is
  # REFUSED — overwriting an installed script post-create is the injection
  # path, and it must go through the cap-gated create route, not a
  # re-instantiate. Returns the absolute script path on success.
  @doc false
  @spec install_script(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def install_script(config_dir, script) when is_binary(config_dir) and is_binary(script) do
    path = Path.join(config_dir, @script_filename)

    case File.read(path) do
      {:ok, ^script} ->
        # Identical — idempotent.
        {:ok, path}

      {:ok, _different} ->
        # The injection gate: refuse to overwrite an installed script with
        # different content.
        {:error, :script_immutable}

      {:error, :enoent} ->
        case File.write(path, script) do
          :ok ->
            _ = File.chmod(path, 0o600)
            {:ok, path}

          {:error, reason} ->
            {:error, {:script_write_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:script_read_failed, reason}}
    end
  end

  # --- subprocess lifecycle ------------------------------------------------

  # PR-3 ensure-subprocess-alive callback — re-spawn from the EXISTING
  # installed script (never re-write). `respawn_data` MUST carry the
  # `"script_path"` + `"cwd"` the original instantiate recorded.
  @impl Ezagent.Kind.Template
  def ensure_subprocess_alive(%URI{} = agent_uri, respawn_data) when is_map(respawn_data) do
    with {:ok, script_path} <- fetch_respawn_key(respawn_data, "script_path"),
         {:ok, cwd} <- fetch_respawn_key(respawn_data, "cwd") do
      ensure_python_alive(agent_uri, script_path, cwd)
    end
  end

  def ensure_subprocess_alive(_, _), do: {:error, :invalid_args}

  defp fetch_respawn_key(data, key) do
    case Map.fetch(data, key) do
      {:ok, v} when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, {:missing_respawn_key, key}}
    end
  end

  defp ensure_python_alive(agent_uri, script_path, cwd) do
    AgentLifecycle.ensure_alive(build_spec(agent_uri, script_path, cwd))
  end

  @doc """
  Build py's `%Spec{}` for the per-agent Python subprocess. Shared by
  `instantiate/3` (create) and `Behavior.PyAgent.activate/2` (cold-restart
  respawn) so both produce the identical spec. py owns its own Spec (the
  AgentLifecycle contract is "caller builds the Spec").
  """
  @spec build_spec(URI.t(), String.t(), String.t()) :: Spec.t()
  def build_spec(%URI{} = agent_uri, script_path, cwd) do
    %Spec{
      handle: agent_uri,
      command: :uv_script,
      script_path: script_path,
      cwd: cwd,
      env: %{
        "EZAGENT_PYTHON_LIB_DIR" => python_lib_dir(),
        "EZAGENT_AGENT_URI" => Ezagent.URI.stable_key(agent_uri)
      },
      # Generous ping timeout for a cold uv cache (first run may provision).
      ping_timeout_ms: 120_000,
      # The whole point of py is a REAL subprocess; force off the
      # test-env :not_alive short-circuit (mirrors np's test_mode_override/0).
      test_mode: test_mode_override()
    }
  end

  defp test_mode_override do
    if Code.ensure_loaded?(Mix) and Mix.env() == :test, do: false, else: nil
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

  # --- Ezagent.UI.Form -----------------------------------------------------

  @impl Ezagent.UI.Form
  def form_fields do
    [
      %{
        name: "agent_uri",
        type: :uri,
        label: "Agent URI",
        required: true,
        placeholder: "py_my-bot"
      },
      %{
        name: "script",
        type: :text,
        label: "Python script (operator-authored)",
        required: true,
        placeholder: "from ezagent_python import method, run\\n@method(\"receive\")\\n..."
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
