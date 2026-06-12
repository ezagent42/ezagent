defmodule EzagentPluginAutoservice.Refresh do
  @moduledoc """
  Post-publish agent refresh for the AutoService vertical.

  `after_publish/1` is called after a successful `CrEngine.publish(tid)` to
  bring already-provisioned agents in sync with the newly-published release
  content.

  ## Slow cc agent

  Re-renders the slow agent's `CLAUDE.md` from the new `_current` release
  (`TenantRuntime.materialize(tid, role, :release)` re-points the work-dir
  skills/kb symlinks, then `SoulRenderer.full_claude_md/3` renders soul +
  skill-index) and rewrites `<work_dir>/CLAUDE.md`. The slow cc agent reads
  its soul from work-dir `CLAUDE.md` at **process start**, so rewriting the
  file is the minimal correct update: the next start (a new session, a
  cold-load, or a crash-restart) reads the published soul.

  A tenant may have several provisioned customer sessions, each with its own
  slow agent work dir (`cc-agents/slow-<customer>-work`, see
  `CustomerSession.maybe_slow_agent/7`). `after_publish/1` rewrites the
  `CLAUDE.md` in **every** such work dir for the tenant — it discovers them on
  disk rather than guessing customer names. `after_publish_for/2` targets one
  customer.

  Note on hot-restart: `claude` reads `CLAUDE.md` only when its process boots,
  so an already-running slow agent does NOT pick up the new soul until it
  restarts. There is no sanctioned plugin-facing entrypoint to force-restart a
  *live* cc PTY, so a forced hot-restart of a running slow agent is a
  documented deferral (it needs a sanctioned cc-runtime respawn dispatch —
  cc-runtime is Allen's domain). For the demo flow ("publish → next session
  reflects it") rewriting `CLAUDE.md` is sufficient.

  This module does NOT read the cc agent's snapshot or cross-Kind slices and
  does NOT import `SnapshotStore` / `EventLog` / `StateRebuilder` (plugin
  contract §11).

  ## Fast curl agent

  The fast curl agent holds its `system_prompt` in live Kind state, so it is
  updated in place via a `curl_agent.configure` dispatch (a
  `{:set, :system_prompt, _}` effect) — no restart needed. The new prompt is
  the tenant release `config/fast_ack_prompt.md` (the same source
  `CustomerSession.load_fast_prompt/1` reads at provision time).

  ## Failure semantics

  Returns `:ok` once the slow `CLAUDE.md`(s) are rewritten (the content
  rewrite is the gate). A respawn/configure failure on the fast side is
  non-fatal (logged as a warning). Returns `{:error, reason}` only on a fatal
  provision/write failure (materialize raises, or `File.write` of a
  `CLAUDE.md` fails).
  """

  alias EzagentPluginContent.Soul.SoulRenderer
  alias EzagentPluginContent.Tenant.TenantRuntime

  require Logger

  @default_role "slow"

  @doc """
  Refresh every provisioned agent for tenant `tid` after a publish.

  Rewrites each slow agent work-dir `CLAUDE.md` from the new release (read on
  the agent's next start) and updates live fast curl agents' `system_prompt`
  via dispatch.

  Returns `:ok` on success (including a degraded-but-non-fatal fast-configure
  error). Returns `{:error, reason}` only on a fatal slow provision/write
  failure.
  """
  @spec after_publish(String.t(), keyword()) :: :ok | {:error, term()}
  def after_publish(tid, opts \\ []) when is_binary(tid) do
    role = Keyword.get(opts, :role, @default_role)
    slot_values = Keyword.get(opts, :soul_slot_values, %{})

    with :ok <- refresh_slow_agents(tid, role, slot_values) do
      refresh_fast_agents(tid)
    end
  end

  @doc """
  Refresh the slow agent `CLAUDE.md` for a single customer work dir and the
  tenant's fast curl agents.

  `customer_name` is the bare customer segment (e.g. `"charlie"`), matching
  `Uris.slow_agent_create_name/1`'s `slow-<customer>` convention.
  """
  @spec after_publish_for(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def after_publish_for(tid, customer_name, opts \\ [])
      when is_binary(tid) and is_binary(customer_name) do
    role = Keyword.get(opts, :role, @default_role)
    slot_values = Keyword.get(opts, :soul_slot_values, %{})

    work_dir = slow_work_dir(tid, customer_name)

    with :ok <- rewrite_slow_claude_md(tid, role, slot_values, work_dir) do
      refresh_fast_agents(tid)
    end
  end

  # ---------------------------------------------------------------------------
  # Slow agent: rewrite work-dir CLAUDE.md from the new release.
  # ---------------------------------------------------------------------------

  defp refresh_slow_agents(tid, role, slot_values) do
    # Re-point the per-role release work dir's skills/kb symlinks at the new
    # _current. materialize/3 is idempotent (it rm's + re-creates the symlinks).
    _ = TenantRuntime.materialize(tid, role, :release)

    work_dirs = slow_work_dirs(tid)

    if work_dirs == [] do
      Logger.info("Refresh: no provisioned slow work dirs for tenant #{tid}, nothing to rewrite")
      :ok
    else
      Enum.reduce_while(work_dirs, :ok, fn work_dir, _acc ->
        case rewrite_slow_claude_md(tid, role, slot_values, work_dir) do
          :ok -> {:cont, :ok}
          {:error, _} = err -> {:halt, err}
        end
      end)
    end
  end

  # Re-render CLAUDE.md from the new release content and write it to work_dir.
  # Mirrors CustomerSession.maybe_slow_agent/7's render path so a refreshed
  # CLAUDE.md is byte-identical to a freshly-provisioned one for the same soul.
  defp rewrite_slow_claude_md(tid, role, slot_values, work_dir) do
    soul_templates = load_soul_templates(tid, role)
    skill_index = load_skill_index(tid, role)
    rendered = SoulRenderer.full_claude_md(soul_templates, slot_values, skill_index)

    claude_md_path = Path.join(work_dir, "CLAUDE.md")
    _ = File.mkdir_p(work_dir)

    case File.write(claude_md_path, rendered) do
      :ok ->
        Logger.info(
          "Refresh: slow CLAUDE.md rewritten — #{claude_md_path} (#{byte_size(rendered)} bytes). " <>
            "Live slow agents read it on their next start; a forced hot-restart of a running " <>
            "slow agent is deferred (needs a sanctioned cc respawn dispatch — cc-runtime domain)."
        )

        :ok

      {:error, reason} ->
        {:error, {:slow_claude_md_write_failed, claude_md_path, reason}}
    end
  end

  # Discover every provisioned slow agent work dir for the tenant:
  # base/<tid>/cc-agents/slow-*-work (see CustomerSession.maybe_slow_agent/7).
  defp slow_work_dirs(tid) do
    [TenantRuntime.base_dir(), tid, "cc-agents", "slow-*-work"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
  end

  defp slow_work_dir(tid, customer_name) do
    Path.join([TenantRuntime.base_dir(), tid, "cc-agents", "slow-#{customer_name}-work"])
  end

  # Load soul templates for a role from the tenant release directory.
  # Mirrors CustomerSession.load_soul_templates/2.
  defp load_soul_templates(tid, role) do
    release_current = TenantRuntime.current_release_path(tid)
    direct = Path.join([release_current, "soul", "#{role}.md"])
    layered = Path.join([release_current, "soul", role, "soul.md"])

    cond do
      File.exists?(direct) -> [File.read!(direct)]
      File.exists?(layered) -> [File.read!(layered)]
      true -> []
    end
  end

  # Load skill index for a role from the tenant release directory.
  # Mirrors CustomerSession.load_skill_index/2.
  defp load_skill_index(tid, role) do
    index_path =
      Path.join([TenantRuntime.current_release_path(tid), "skills", role, "SKILL_INDEX.md"])

    if File.exists?(index_path), do: File.read!(index_path), else: ""
  end

  # ---------------------------------------------------------------------------
  # Fast agent: update system_prompt via curl_agent.configure dispatch.
  # ---------------------------------------------------------------------------

  defp refresh_fast_agents(tid) do
    new_prompt = load_fast_prompt(tid)

    cond do
      not (is_binary(new_prompt) and byte_size(new_prompt) > 0) ->
        Logger.info("Refresh: fast has no system_prompt in release content, skipping")
        :ok

      true ->
        dispatch_fast_configure(tid, new_prompt)
    end
  end

  # Load the fast ACK prompt from the tenant release config (the same source
  # CustomerSession.load_fast_prompt/1 reads). Returns "" if neither the
  # release nor the skeleton default is present.
  defp load_fast_prompt(tid) do
    release_path =
      Path.join([TenantRuntime.current_release_path(tid), "config", "fast_ack_prompt.md"])

    skeleton_default =
      Path.join(
        :code.priv_dir(:ezagent_plugin_content),
        "skeleton/config/fast_ack_prompt.md"
      )

    cond do
      File.exists?(release_path) -> File.read!(release_path)
      File.exists?(skeleton_default) -> File.read!(skeleton_default)
      true -> ""
    end
  end

  defp dispatch_fast_configure(tid, new_prompt) do
    live_fast = live_fast_agents(tid)

    if live_fast == [] do
      Logger.info("Refresh: no live fast agents for tenant #{tid}, skipping configure dispatch")
    else
      ctx = %{
        caller: Ezagent.Entity.User.admin_uri(),
        caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
        reply: {:caller_inbox, self()}
      }

      Enum.each(live_fast, fn agent_uri ->
        target = Ezagent.URI.new!("#{URI.to_string(agent_uri)}?action=curl_agent.configure")

        result =
          Ezagent.Invocation.dispatch(%Ezagent.Invocation{
            target: target,
            mode: :call,
            args: %{system_prompt: new_prompt},
            ctx: ctx
          })

        case result do
          {:ok, _} ->
            Logger.info("Refresh: fast agent prompt updated — #{URI.to_string(agent_uri)}")

          other ->
            Logger.warning(
              "Refresh: fast agent configure (non-fatal) — #{URI.to_string(agent_uri)}: #{inspect(other)}"
            )
        end
      end)
    end

    :ok
  end

  # Enumerate live fast curl agents for the tenant. The fast agent URI is
  # entity://<ws>/agent/curl_fast-<customer> (see Uris.fast_agent_uri/1), so we
  # match entity agents in workspace `tid` whose name starts with "curl_fast-".
  defp live_fast_agents(tid) do
    Ezagent.KindRegistry.list_all()
    |> Enum.flat_map(fn {uri_str, _pid} ->
      with {:ok, %URI{scheme: "entity"} = uri} <- Ezagent.URI.parse(uri_str),
           {:ok, ^tid} <- Ezagent.URI.workspace_name(uri),
           {:ok, name} when is_binary(name) <- Ezagent.URI.name(uri),
           true <- String.starts_with?(name, "curl_fast-") do
        [uri]
      else
        _ -> []
      end
    end)
  end
end
