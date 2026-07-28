defmodule Ezagent.Credential.HomeRuntime do
  @moduledoc """
  Shared per-agent config-home runtime for file-backed agent flavors.

  The cc and codex Template Classes keep their flavor-specific public entrypoints
  and pass their module here for namespace and credential callback data.
  """

  require Logger

  @config_complete_marker ".ezagent-config-complete"

  # #201-cred (codex r2 HIGH-4 / r3 MEDIUM-5) — the grant context threads TWO
  # distinct incarnation ids:
  #
  #   `{:grant, agent_uri_str, fetched_incarnation_id, version,
  #     minted_incarnation_id}`
  #
  #   * `fetched_incarnation_id` + `version` — the ACTIVE grant the launch will
  #     use, read at materialization time. The pre-launch revalidation
  #     (`revalidate_grant_before_launch/1`) re-checks `(agent_uri,
  #     fetched_incarnation_id, version)`, so a delete+reinsert at the same
  #     version or two reapprovals racing one version number can no longer pass a
  #     stale materializer through. May be a PRE-EXISTING grant (a no-pending
  #     created-winner over a durable row) — possibly `nil` for a legacy row.
  #   * `minted_incarnation_id` — EXACTLY what THIS spawn minted, or `nil` if it
  #     minted nothing (codex r3 MEDIUM-5). COMPENSATION keys off this, never the
  #     fetched id: a launch failure must delete only the grant this spawn
  #     created and must NEVER delete a pre-existing grant it merely read (whose
  #     `fetched_incarnation_id` — e.g. a backfilled `"legacy:<id>"` — is not a
  #     mint receipt of this spawn).
  @type grant_ctx ::
          {:grant, String.t(), String.t() | nil, non_neg_integer(), String.t() | nil} | nil
  @type create_result ::
          {:ok, String.t() | nil}
          | {:ok, String.t(),
             {:grant, String.t(), String.t() | nil, non_neg_integer(), String.t() | nil}}
          | {:error, term()}

  # #1201 A② — the SHARED host-login-home derivation for file-backed flavors
  # (cc/codex delegate here with their env var + default dirname, mirroring the
  # CLIs' own resolution order: env override, else `~/<dirname>`). Lives here —
  # not per-flavor — per the FF-1 `cross_file_duplicate_fn_groups` gate.
  @doc false
  @spec host_login_dir(String.t(), String.t()) :: String.t() | nil
  def host_login_dir(env_var, home_dirname)
      when is_binary(env_var) and is_binary(home_dirname) do
    case System.get_env(env_var) do
      dir when is_binary(dir) and dir != "" ->
        dir

      _ ->
        case System.user_home() do
          home when is_binary(home) -> Path.join(home, home_dirname)
          _ -> nil
        end
    end
  end

  @doc false
  @spec put_agent_config_dir(map(), String.t() | nil) :: map()
  def put_agent_config_dir(tmpl, nil) when is_map(tmpl), do: tmpl

  def put_agent_config_dir(tmpl, dir) when is_map(tmpl),
    do: Map.put(tmpl, "agent_config_dir", dir)

  @doc """
  #201-cred (codex r2 NEW-HIGH-3) — the plugin created-winner arm calls this to
  thread its `:started ∧ created?` witness into the `tmpl`'s cascade map, so the
  deferred mint in `materialize_cascade/6` can prove the mint is on the
  created-winner arm (`GrantMint.maybe_mint/3` fail-closes without it). A no-op
  when there is no cascade map (a non-cascade / no-credential-source agent mints
  nothing) or no witness (a rehydrating winner never mints). NEVER call this off
  the created-winner arm — a witness only exists there.
  """
  @spec put_cascade_created_witness(map(), Ezagent.Kind.CreatedWitness.t() | nil) :: map()
  def put_cascade_created_witness(tmpl, nil) when is_map(tmpl), do: tmpl

  def put_cascade_created_witness(tmpl, witness) when is_map(tmpl) do
    case Map.get(tmpl, "cascade") do
      %{} = cascade -> Map.put(tmpl, "cascade", Map.put(cascade, :created_witness, witness))
      _ -> tmpl
    end
  end

  @doc false
  @spec resolve_config_home(URI.t(), map(), module(), keyword()) :: String.t() | nil
  def resolve_config_home(%URI{} = agent_uri, tmpl, template_module, opts \\ [])
      when is_map(tmpl) do
    cond do
      valid_dir?(Map.get(tmpl, "agent_config_dir")) ->
        Map.get(tmpl, "agent_config_dir")

      valid_dir?(Map.get(tmpl, "allocated_config_dir")) ->
        Map.get(tmpl, "allocated_config_dir")

      valid_dir?(Map.get(tmpl, "config_dir")) ->
        agent_config_dir(agent_uri, template_module)

      config_dir_present_but_malformed?(tmpl) ->
        case Keyword.get(opts, :on_malformed, nil) do
          {:raise, message_fun} when is_function(message_fun, 1) ->
            raise ArgumentError, message_fun.(Map.get(tmpl, "config_dir"))

          nil ->
            nil
        end

      true ->
        nil
    end
  end

  @doc false
  @spec valid_dir?(term()) :: boolean()
  def valid_dir?(dir) when is_binary(dir) and dir != "", do: true
  def valid_dir?(_), do: false

  @doc false
  @spec config_dir_present_but_malformed?(map()) :: boolean()
  def config_dir_present_but_malformed?(tmpl) when is_map(tmpl) do
    case Map.fetch(tmpl, "config_dir") do
      :error -> false
      {:ok, value} -> not valid_dir?(value)
    end
  end

  @doc false
  @spec agent_config_dir(URI.t(), module()) :: String.t()
  def agent_config_dir(%URI{} = agent_uri, template_module) when is_atom(template_module) do
    Ezagent.Sandbox.ConfigDir.path(
      agent_uri,
      Ezagent.Kind.Template.namespace_of(template_module)
    )
  end

  @doc false
  @spec create_agent_config_dir(URI.t(), map(), module(), keyword()) :: create_result()
  def create_agent_config_dir(%URI{} = agent_uri, tmpl, template_module, opts \\ [])
      when is_map(tmpl) and is_atom(template_module) do
    case Map.fetch(tmpl, "config_dir") do
      :error ->
        {:ok, nil}

      {:ok, ref} when is_binary(ref) and ref != "" ->
        case Map.fetch(tmpl, "allocated_config_dir") do
          {:ok, target} when is_binary(target) and target != "" ->
            materialize_config_dir(agent_uri, target, ref, tmpl, template_module, opts)

          _ ->
            {:error, :config_dir_not_allocated}
        end

      {:ok, bad} ->
        {:error, {:invalid_config_dir, bad}}
    end
  end

  @doc false
  @spec create_agent_config_dir_with_grant(URI.t(), map(), module(), keyword()) ::
          {:ok, String.t() | nil, grant_ctx()} | {:error, term()}
  def create_agent_config_dir_with_grant(%URI{} = agent_uri, tmpl, template_module, opts \\ [])
      when is_map(tmpl) and is_atom(template_module) do
    case create_agent_config_dir(agent_uri, tmpl, template_module, opts) do
      {:ok, dir, grant_ctx} -> {:ok, dir, grant_ctx}
      {:ok, dir} -> {:ok, dir, nil}
      {:error, _} = err -> err
    end
  end

  @doc """
  True iff a subprocess may be launched against the per-agent config home `dir`.

  Launchable means EITHER:

    * `stage_and_swap/7` committed the home and wrote `#{@config_complete_marker}`
      (a freshly materialized home), OR
    * the home already carries one of `template_module.credential_relpaths/0`
      (a home materialized before the marker existed, or provisioned by an
      operator's interactive login) — the same signal `materialize_single_reference/5`
      uses to decide a target is a real user home worth overlaying.

  A directory that merely EXISTS is neither: `OnboardingBootstrap` `mkdir_p`s the
  config home before the copy, so an un-marked, credential-less dir can hold a
  `.claude.json` and nothing else. Launching against THAT produces an agent that
  can never authenticate, and the subsequent `atomic_replace` renames the
  directory out from under the running process (chain B / #1096). Callers MUST
  gate the subprocess launch on this.
  """
  @spec config_dir_launchable?(String.t() | nil, module()) :: boolean()
  def config_dir_launchable?(nil, _template_module), do: false

  def config_dir_launchable?(dir, template_module)
      when is_binary(dir) and is_atom(template_module) do
    File.dir?(dir) and
      (File.exists?(Path.join(dir, @config_complete_marker)) or
         has_user_credentials?(dir, template_module))
  end

  @doc "The sentinel file `stage_and_swap/7` writes last, marking a config home complete."
  @spec config_complete_marker() :: String.t()
  def config_complete_marker, do: @config_complete_marker

  @doc """
  The pre-launch grant re-validation, called by every file-flavor arm IMMEDIATELY
  before the irreversible launch side effect (sidecar/PTY `Port.open`; curl's
  cross-actor api-key slice write at `curl_agent.ex:139`).

  `GrantRow.revalidate_version!/3` re-reads the grant AND (codex r2 NEW-HIGH-2)
  re-runs `generations_current?/1` against the FRESH active authority rows
  (`Ezagent.Cap.Authority.current_generation/1` is a live `Repo.one`), so a holder
  or source `regenesis` that COMMITTED before this call is DENIED
  (`{:error, {:grant_changed_before_launch, _}}`) and the arm tears down the
  secret-bearing config dir before anything launches.

  ## #201-cred (codex r3 HIGH-2) — the residual TOCTOU window, precisely

  A residual window remains and is STRUCTURALLY UNAVOIDABLE for an external
  launch: a `regenesis` that commits in the micro-interval AFTER this call
  returns `:ok` and BEFORE the irreversible op completes (the `Port.open`
  syscall, or the `Invocation.dispatch` that writes curl's api-key slice in
  ANOTHER Kind's process) would launch under the now-retired authority
  generation. It cannot be closed by holding an authority-generation lease across
  the side effect, because:

    * the secret is ALREADY materialized to the on-disk config home before this
      check (a denied launch tears the home down; it cannot un-read a byte a
      subprocess is mid-read), and
    * the irreversible op is an OS process exec / a cross-process actor dispatch —
      NOT a same-connection DB write — so no `SELECT ... FOR UPDATE` on the active
      authority row (the lock `GrantMint.insert_guarded/4` legitimately holds
      across the MINT, a pure DB transaction) can be held across it without
      pinning a DB connection for the subprocess's entire lifetime and serializing
      all regenesis behind live agents.

  The window is therefore MINIMIZED (this re-check is the LAST thing before the
  launch) and BOUNDED to the check→exec micro-interval; the MINT itself is
  lock-serialized against regenesis, and every subsequent MATERIALIZATION re-reads
  generations, so a stale-generation grant can never be re-used after the fact —
  only this one in-flight launch can slip the sub-interval. A future full closure
  would require the launch to present a short-lived, generation-bound lease token
  the target verifies at exec time (a `Cap.Authority`-style signing design) — out
  of scope for this round.
  """
  @spec revalidate_grant_before_launch(grant_ctx()) :: :ok | {:error, term()}
  def revalidate_grant_before_launch(nil), do: :ok

  def revalidate_grant_before_launch({:grant, agent_uri_str, incarnation_id, version, _minted}) do
    case Ezagent.Credential.GrantRow.revalidate_version!(agent_uri_str, incarnation_id, version) do
      :ok -> :ok
      {:error, :grant_changed} -> {:error, {:grant_changed_before_launch, agent_uri_str}}
    end
  end

  @doc """
  #201-cred (codex r2 HIGH-2) — CONFIRMED compensation of the grant a
  created-winner minted during materialization, for a spawn that failed
  AFTER the mint (role bootstrap / pre-launch revalidation / subprocess
  launch). Deletes exactly the minted incarnation (ABA-safe); a compensation
  failure propagates as `{:error, :grant_compensation_failed}` — the caller
  must surface it, never swallow it. `nil` ctx (no grant minted) → `:ok`.
  """
  @spec compensate_grant_ctx(grant_ctx()) :: :ok | {:error, :grant_compensation_failed}
  def compensate_grant_ctx(nil), do: :ok

  # #201-cred (codex r3 MEDIUM-5) — compensation keys off the MINTED incarnation
  # (5th element), NEVER the fetched one. A `nil` minted id means THIS spawn
  # minted nothing (a no-pending created-winner over a pre-existing grant, or a
  # respawn) — there is nothing for it to compensate, and it must NEVER delete a
  # pre-existing grant it merely read (whose fetched id — e.g. a backfilled
  # `"legacy:<id>"` — is not a mint receipt of this spawn). `GrantMint.compensate/3`'s
  # `is_binary` guard would also FunctionClauseError on `nil`.
  def compensate_grant_ctx({:grant, _agent_uri_str, _fetched_id, _version, nil}), do: :ok

  def compensate_grant_ctx({:grant, agent_uri_str, _fetched_id, _version, minted_incarnation_id}) do
    Ezagent.Credential.GrantMint.compensate(agent_uri_str, minted_incarnation_id)
  end

  @doc """
  The incarnation THIS spawn MINTED (5th element), or nil if it minted nothing.

  This is the compensation receipt the plugin threads into its instantiate meta
  as `:grant_incarnation_id`, which the chokepoint's `Rollback.fresh_spawn`
  deletes on a post-spawn-obligation failure. #201-cred (codex r3 MEDIUM-5) — it
  is the MINTED id, never the fetched one, so a rollback can never delete a
  pre-existing grant this spawn only read.
  """
  @spec grant_ctx_incarnation(grant_ctx()) :: String.t() | nil
  def grant_ctx_incarnation(nil), do: nil
  def grant_ctx_incarnation({:grant, _uri, _fetched_id, _version, minted_incarnation_id}),
    do: minted_incarnation_id

  @doc """
  #201-cred (codex r2 HIGH-2) — the SHARED post-mint spawn-failure path for
  every file-flavor plugin arm: CONFIRM-compensate exactly the grant
  incarnation this spawn minted (`compensate_grant_ctx/1` — a
  revoked/reapproved row under a NEWER incarnation is never touched), THEN
  run the config-dir teardown (`handle_spawn_failure/4`). A compensation
  failure is surfaced COMPOSITE (`{reason, :grant_compensation_failed}`) — a
  silently leaked grant is a security-critical residue, never collapsed into
  the primary error.
  """
  @spec compensate_spawn_failure(URI.t(), grant_ctx(), term(), module(), String.t()) ::
          {:error, term()}
  def compensate_spawn_failure(agent_uri, grant_ctx, reason, template_module, log_prefix) do
    case compensate_grant_ctx(grant_ctx) do
      :ok ->
        handle_spawn_failure(agent_uri, reason, template_module, log_prefix)

      {:error, :grant_compensation_failed} ->
        handle_spawn_failure(
          agent_uri,
          {reason, :grant_compensation_failed},
          template_module,
          log_prefix
        )
    end
  end

  @doc """
  #201-cred (codex r3 NEW-HIGH-1) — run the post-materialize LAUNCH
  (sidecar/PTY start) under the grant-compensation boundary.

  The deferred mint runs INSIDE `create_agent_config_dir_with_grant/4`'s own
  rescue, but the plugin launches the subprocess AFTERWARDS — OUTSIDE that rescue
  and outside `materialize_and_compensate/3`. A RAISE in that launch (a `Port`
  open, a file op, a match error in sidecar wiring) previously bypassed grant
  compensation entirely: `TemplateSpawn` caught and re-raised while the minted
  grant stayed durable.

  This wraps `launch_fun`. A clean `{:ok, _}`/`{:error, _}` return passes through
  untouched (the plugin handles a clean launch error via its own
  `compensate_spawn_failure/5`). On a RAISE/THROW it best-effort tears down the
  half-started Kind + the secret-bearing config dir, then CONFIRM-compensates
  exactly the minted incarnation and re-raises — surfacing an exhausted
  compensation as `GrantCompensationLeaked`, never discarding it. `grant_ctx`
  carries the minted incarnation (nil = this spawn minted nothing → the grant
  step is a no-op, so a rehydrating/no-pending winner never over-compensates).
  """
  @spec launch_under_grant_compensation(
          URI.t(),
          grant_ctx(),
          module(),
          String.t(),
          (-> result)
        ) :: result
        when result: term()
  def launch_under_grant_compensation(
        %URI{} = agent_uri,
        grant_ctx,
        template_module,
        log_prefix,
        launch_fun
      )
      when is_atom(template_module) and is_binary(log_prefix) and is_function(launch_fun, 0) do
    try do
      launch_fun.()
    rescue
      exception ->
        on_launch_raise(agent_uri, template_module, log_prefix)

        Ezagent.Credential.GrantMint.reraise_compensating(
          URI.to_string(agent_uri),
          grant_ctx_incarnation(grant_ctx),
          exception,
          __STACKTRACE__
        )
    catch
      kind, reason ->
        on_launch_raise(agent_uri, template_module, log_prefix)

        Ezagent.Credential.GrantMint.raise_compensating(
          URI.to_string(agent_uri),
          grant_ctx_incarnation(grant_ctx),
          kind,
          reason,
          __STACKTRACE__
        )
    end
  end

  # Best-effort teardown of the half-started spawn on a LAUNCH raise: stop the
  # Kind (so a partially-started agent does not linger) and remove the
  # secret-bearing config dir (so no credential residue survives the abort). The
  # MINTED grant is compensated separately by `GrantMint.reraise_compensating/4`.
  defp on_launch_raise(%URI{} = agent_uri, template_module, log_prefix) do
    _ = Ezagent.Kind.terminate!(agent_uri)
    _ = rollback_agent_config_dir(agent_uri, template_module, log_prefix)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc false
  @spec handle_spawn_failure(URI.t(), term(), module(), String.t()) :: {:error, term()}
  def handle_spawn_failure(
        %URI{} = agent_uri,
        {:grant_changed_before_launch, _} = reason,
        template_module,
        log_prefix
      ) do
    case rollback_agent_config_dir(agent_uri, template_module, log_prefix) do
      :ok ->
        {:error, reason}

      {:error, cleanup_reason} ->
        {:error, {:grant_revoked_cleanup_failed, agent_uri, cleanup_reason}}
    end
  end

  def handle_spawn_failure(%URI{} = agent_uri, reason, template_module, log_prefix) do
    case rollback_agent_config_dir(agent_uri, template_module, log_prefix) do
      :ok ->
        {:error, reason}

      {:error, cleanup_reason} ->
        {:error, {:config_dir_cleanup_failed, agent_uri, reason, cleanup_reason}}
    end
  end

  @doc false
  @spec grant_revoked_for_restart?(URI.t()) :: boolean()
  def grant_revoked_for_restart?(%URI{} = agent_uri) do
    case Ezagent.Credential.GrantRow.get_for_agent(URI.to_string(agent_uri)) do
      %Ezagent.Credential.GrantRow{revoked_at: nil} -> false
      %Ezagent.Credential.GrantRow{} -> true
      nil -> false
    end
  rescue
    _ -> false
  end

  defp rollback_agent_config_dir(agent_uri, template_module, log_prefix) do
    dir = agent_config_dir(agent_uri, template_module)

    case File.rm_rf(dir) do
      {:ok, _} ->
        :ok

      {:error, reason, _path} ->
        Logger.warning(
          "#{log_prefix}: rollback of #{dir} failed: #{inspect(reason)} " <>
            "(agent_uri=#{URI.to_string(agent_uri)})"
        )

        {:error, reason}
    end
  end

  defp materialize_config_dir(
         %URI{} = agent_uri,
         target,
         reference_dir,
         tmpl,
         template_module,
         opts
       )
       when is_map(tmpl) do
    with :ok <- recover_orphaned_or_fail(target) do
      case Map.get(tmpl, "cascade") do
        %{} = cascade ->
          materialize_cascade(agent_uri, target, cascade, tmpl, template_module, opts)

        _ ->
          materialize_single_reference(target, reference_dir, tmpl, template_module, opts)
      end
    end
  end

  defp recover_orphaned_or_fail(target) do
    case Ezagent.Agent.Materializer.recover_orphaned(target) do
      :ok -> :ok
      {:recovered, _} -> :ok
      {:error, reason} -> {:error, {:config_dir_recover_failed, reason}}
    end
  end

  defp materialize_cascade(%URI{} = agent_uri, target, cascade, tmpl, template_module, opts) do
    marker = Path.join(target, @config_complete_marker)
    staging = "#{target}.staging-#{System.unique_integer([:positive])}"
    _ = File.rm_rf(staging)

    layer_dirs = Map.fetch!(cascade, :layer_dirs)
    source_dir_for = Map.fetch!(cascade, :source_dir_for)

    result =
      try do
        with :ok <- Ezagent.Agent.Materializer.merge_layers(staging, layer_dirs),
             :ok <- materialize_sandbox_skills(staging, tmpl),
             :ok <- materialize_plugin_manifest(staging, tmpl),
             :ok <- File.chmod(staging, 0o700),
             :ok <- File.write(Path.join(staging, Path.basename(marker)), "ok\n"),
             # #201-cred (codex r2 HIGH-1 + NEW-HIGH-3) — THE DEFERRED MINT. The
             # cascade may carry a `:pending_grant` descriptor (authorized at
             # domain resolution time); the durable grant is minted HERE — inside
             # the created-winner's materialization boundary — never earlier.
             # `GrantMint.maybe_mint/3` REQUIRES the created-winner witness the
             # plugin arm injected into the cascade map (`:created_witness`) from
             # its `:started ∧ created?` spawn receipt; without it the mint
             # fail-closes (`:missing_created_winner_witness`). Respawn/rehydrated
             # cascades carry neither pending grant nor witness and mint nothing.
             {:ok, minted} <-
               Ezagent.Credential.GrantMint.maybe_mint(
                 agent_uri,
                 Map.get(cascade, :pending_grant),
                 Map.get(cascade, :created_witness)
               ),
             {:ok, {^target, version, incarnation_id}} <-
               materialize_and_compensate(agent_uri, minted, fn ->
                 Ezagent.Agent.Materializer.materialize_with_grant(%{
                   agent_uri: URI.to_string(agent_uri),
                   staging: staging,
                   secret_relpaths: template_module.secret_relpaths(),
                   source_dir_for: source_dir_for,
                   commit: fn {version, incarnation_id} ->
                     with :ok <- chmod_credential_files(staging, template_module, opts),
                          :ok <- swap_into_place(staging, target) do
                       {:ok, {target, version, incarnation_id}}
                     end
                   end
                 })
               end) do
          # #201-cred (codex r3 MEDIUM-5) — carry the MINTED incarnation (nil if
          # this spawn minted nothing) SEPARATELY from the fetched
          # `incarnation_id`. `version`/`incarnation_id` are the active grant the
          # launch revalidates against (possibly a pre-existing row); the minted
          # id is the ONLY thing a later spawn-failure may compensate.
          {:ok, target, version, incarnation_id,
           Ezagent.Credential.GrantMint.grant_incarnation(minted)}
        end
      rescue
        # #201-cred (codex r2 NEW-HIGH-1) — a raise in the post-mint region has
        # already CONFIRM-compensated the minted grant (inside
        # `materialize_and_compensate/3`); here we additionally clear the
        # secret-bearing staging dir so no credential residue is left, then
        # re-raise so `TemplateSpawn` finalizes the aborted spawn.
        exception ->
          _ = File.rm_rf(staging)
          reraise exception, __STACKTRACE__
      catch
        kind, reason ->
          _ = File.rm_rf(staging)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    case result do
      {:ok, ^target, version, incarnation_id, minted_incarnation_id} ->
        {:ok, target,
         {:grant, URI.to_string(agent_uri), incarnation_id, version, minted_incarnation_id}}

      {:error, reason} ->
        _ = File.rm_rf(staging)
        {:error, {:cascade_materialize_failed, reason}}
    end
  end

  # #201-cred (codex r2 HIGH-2 + NEW-HIGH-1) — run the grant-leased
  # materialization; if it fails AFTER this call minted, CONFIRM-compensate
  # exactly the minted incarnation before returning/propagating the failure.
  #
  #   * A RETURNED `{:error, reason}` is compensated and surfaced COMPOSITE on a
  #     compensation failure (`{:materialize_failed_and_grant_compensation_failed,
  #     ...}`) — never collapsed into the primary error (a silently leaked grant
  #     is a security-critical residue).
  #
  #   * A RAISE/THROW anywhere in the post-mint region — `fetch_for_materialize`,
  #     `source_dir_for`, a secret read, or the commit — previously skipped
  #     compensation ENTIRELY and left the just-minted grant durable while
  #     `TemplateSpawn` re-raised (codex r2 NEW-HIGH-1). The rescue/catch below
  #     routes through `GrantMint.reraise_compensating/4`: CONFIRM-compensate the
  #     minted incarnation, THEN re-raise. #201-cred (codex r3 NEW-HIGH-1) — the
  #     compensation result is NO LONGER `_ =`-discarded: an EXHAUSTED compensation
  #     re-raises a `GrantCompensationLeaked` wrapper (original stacktrace
  #     preserved) so the durable-grant leak is surfaced on the abort, never
  #     silently dropped. On success the original exception propagates unchanged.
  defp materialize_and_compensate(agent_uri, minted, materialize_fun) do
    try do
      case materialize_fun.() do
        {:ok, _} = ok ->
          ok

        {:error, reason} ->
          compensate_after_returned_failure(agent_uri, minted, reason)
      end
    rescue
      exception ->
        Ezagent.Credential.GrantMint.reraise_compensating(
          URI.to_string(agent_uri),
          Ezagent.Credential.GrantMint.grant_incarnation(minted),
          exception,
          __STACKTRACE__
        )
    catch
      kind, reason ->
        Ezagent.Credential.GrantMint.raise_compensating(
          URI.to_string(agent_uri),
          Ezagent.Credential.GrantMint.grant_incarnation(minted),
          kind,
          reason,
          __STACKTRACE__
        )
    end
  end

  defp compensate_after_returned_failure(agent_uri, minted, reason) do
    case Ezagent.Credential.GrantMint.grant_incarnation(minted) do
      nil ->
        {:error, reason}

      incarnation_id ->
        case Ezagent.Credential.GrantMint.compensate(
               URI.to_string(agent_uri),
               incarnation_id
             ) do
          :ok ->
            {:error, reason}

          {:error, :grant_compensation_failed} ->
            {:error, {:materialize_failed_and_grant_compensation_failed, reason, incarnation_id}}
        end
    end
  end

  defp materialize_single_reference(target, reference_dir, tmpl, template_module, opts) do
    marker = Path.join(target, @config_complete_marker)

    cond do
      not File.dir?(reference_dir) ->
        {:error, {:reference_dir_missing, reference_dir}}

      File.dir?(target) and File.exists?(marker) ->
        {:ok, target}

      File.dir?(target) and has_user_credentials?(target, template_module) ->
        stage_and_swap(reference_dir, target, marker, template_module, tmpl, opts,
          overlay: target
        )

      true ->
        stage_and_swap(reference_dir, target, marker, template_module, tmpl, opts)
    end
  end

  defp stage_and_swap(reference_dir, target, marker, template_module, tmpl, opts, swap_opts \\ []) do
    staging = "#{target}.staging-#{System.unique_integer([:positive])}"
    marker_name = Path.basename(marker)
    _ = File.rm_rf(staging)

    with :ok <- File.mkdir_p(Path.dirname(target)),
         {:ok, _} <- File.cp_r(reference_dir, staging),
         :ok <- maybe_overlay(Keyword.get(swap_opts, :overlay), staging),
         :ok <- apply_derived_config(staging, tmpl),
         :ok <- materialize_sandbox_skills(staging, tmpl),
         :ok <- materialize_plugin_manifest(staging, tmpl),
         :ok <- File.chmod(staging, 0o700),
         :ok <- chmod_credential_files(staging, template_module, opts),
         :ok <- File.write(Path.join(staging, marker_name), "ok\n"),
         :ok <- swap_into_place(staging, target) do
      {:ok, target}
    else
      {:error, reason} ->
        _ = File.rm_rf(staging)
        {:error, {stage_error_tag(opts), reason}}

      err ->
        _ = File.rm_rf(staging)
        {:error, {stage_error_tag(opts), err}}
    end
  end

  defp maybe_overlay(nil, _staging), do: :ok

  defp maybe_overlay(src, staging) when is_binary(src) do
    case File.cp_r(src, staging) do
      {:ok, _} -> :ok
      {:error, reason, _path} -> {:error, reason}
    end
  end

  defp apply_derived_config(staging, tmpl) when is_map(tmpl) do
    case Map.get(tmpl, "claude_md") do
      body when is_binary(body) -> File.write(Path.join(staging, "CLAUDE.md"), body)
      _ -> :ok
    end
  end

  defp materialize_sandbox_skills(staging, tmpl) when is_map(tmpl) do
    case sandbox_skill_refs(tmpl) do
      :absent ->
        :ok

      {:ok, skills} ->
        skills_root = Path.join(staging, "skills")

        with {:ok, _} <- File.rm_rf(skills_root),
             :ok <- maybe_mkdir_skills_root(skills_root, skills) do
          copy_sandbox_skills(skills, skills_root)
        end

      {:error, _} = error ->
        error
    end
  end

  defp sandbox_skill_refs(tmpl) do
    cond do
      Map.has_key?(tmpl, "sandbox_content") ->
        skill_refs_from_sandbox_content(Map.get(tmpl, "sandbox_content"))

      Map.has_key?(tmpl, :sandbox_content) ->
        skill_refs_from_sandbox_content(Map.get(tmpl, :sandbox_content))

      true ->
        :absent
    end
  end

  defp skill_refs_from_sandbox_content(%{} = sandbox_content) do
    case Map.fetch(sandbox_content, :skills) do
      {:ok, skills} -> normalize_skill_refs(skills)
      :error -> sandbox_content |> Map.get("skills", :absent) |> normalize_skill_refs()
    end
  end

  defp skill_refs_from_sandbox_content(other), do: {:error, {:invalid_sandbox_content, other}}

  defp normalize_skill_refs(:absent), do: :absent

  defp normalize_skill_refs(skills) when is_list(skills) do
    if Enum.all?(skills, &is_binary/1) do
      {:ok, Enum.uniq(skills)}
    else
      {:error, {:invalid_sandbox_skills, skills}}
    end
  end

  defp normalize_skill_refs(other), do: {:error, {:invalid_sandbox_skills, other}}

  defp maybe_mkdir_skills_root(_skills_root, []), do: :ok
  defp maybe_mkdir_skills_root(skills_root, _skills), do: File.mkdir_p(skills_root)

  defp copy_sandbox_skills(skills, skills_root) do
    Enum.reduce_while(skills, :ok, fn ref, :ok ->
      case copy_sandbox_skill(ref, skills_root) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp copy_sandbox_skill(ref, skills_root) do
    with {:ok, {source_dir, _hash}} <- Ezagent.SkillRegistry.resolve(ref),
         {:ok, _} <- File.cp_r(source_dir, Path.join(skills_root, ref)) do
      :ok
    else
      {:error, {:skill_source_not_found, ^ref}} = error ->
        error

      {:error, reason, path} ->
        {:error, {:skill_copy_failed, ref, path, reason}}

      {:error, reason} ->
        {:error, {:skill_copy_failed, ref, reason}}
    end
  end

  # Writes .claude-plugin/plugin.json into the staging directory so the
  # per-agent config_dir is a valid Claude Code plugin bundle. Headless
  # flavors (cc-headless) load skills via the SDK's `plugins` parameter
  # (bypassing `setting_sources=[]`); PTY flavors are unaffected by the
  # extra file. Only materialized when sandbox skills are present.
  defp materialize_plugin_manifest(staging, tmpl) when is_map(tmpl) do
    case sandbox_skill_refs(tmpl) do
      {:ok, []} -> :ok
      :absent -> :ok
      {:ok, _skills} -> write_plugin_manifest(staging)
      {:error, _} = error -> error
    end
  end

  defp write_plugin_manifest(staging) do
    plugin_dir = Path.join(staging, ".claude-plugin")

    with :ok <- File.mkdir_p(plugin_dir) do
      File.write(Path.join(plugin_dir, "plugin.json"), plugin_manifest_json())
    end
  end

  defp plugin_manifest_json do
    Jason.encode!(%{
      "name" => "ezagent-skills",
      "version" => "1.0.0",
      "description" => "Per-agent skill bundle materialized by Ezagent"
    })
  end

  defp swap_into_place(staging, target) do
    case Ezagent.Agent.Materializer.atomic_replace(staging, target) do
      {:ok, _target} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp chmod_credential_files(dir, template_module, opts) do
    template_module.credential_relpaths()
    |> Enum.reduce_while(:ok, fn relpath, :ok ->
      path = Path.join(dir, relpath)

      if File.exists?(path) do
        case File.chmod(path, 0o600) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, chmod_error(relpath, reason, opts)}
        end
      else
        {:cont, :ok}
      end
    end)
  end

  defp chmod_error(relpath, reason, opts) do
    case Keyword.get(opts, :chmod_error, :tagged) do
      :bare -> {:error, reason}
      :tagged -> {:error, {:chmod_failed, relpath, reason}}
    end
  end

  defp has_user_credentials?(dir, template_module) do
    Enum.any?(template_module.credential_relpaths(), fn relpath ->
      File.exists?(Path.join(dir, relpath))
    end)
  end

  defp stage_error_tag(opts), do: Keyword.fetch!(opts, :stage_error_tag)
end
