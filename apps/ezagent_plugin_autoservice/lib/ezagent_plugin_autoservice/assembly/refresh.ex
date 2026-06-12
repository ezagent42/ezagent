defmodule EzagentPluginAutoservice.Assembly.Refresh do
  @moduledoc """
  Post-publish agent refresh for the AutoService v2 vertical.

  `refresh_agents/1` is called after a successful `Publisher.publish/2` to
  bring agents in sync with the newly-published release content.

  ## Slow cc agent

  1. `TenantContent.provision_context(tid, "slow", source: :release)` —
     re-renders the soul + skill-index from the new `_current` release.
  2. Rewrites `<work_dir>/CLAUDE.md` with the fresh content. The slow agent
     reads its soul from work-dir CLAUDE.md at **process start**; rewriting
     the file is the minimal correct update so the next start (a new session,
     a cold-load, or a crash-restart) reads the published soul.

  Note on hot-restart: `claude` reads CLAUDE.md only when its process boots,
  so an already-running slow agent does NOT pick up the new soul until it
  restarts. There is no sanctioned plugin-facing entrypoint to force-restart
  a *live* cc PTY (`CcAgent.ensure_subprocess_alive/2` is a *revive-if-dead*
  gate — it is a no-op when the PTY is alive, by design). A forced hot-restart
  of a running slow agent is therefore a documented deferral: it needs a
  sanctioned cc-runtime respawn/restart dispatch (cc-runtime is Allen's
  domain). For the demo flow ("publish → next session reflects it") this is
  sufficient: a newly-provisioned session reads fresh `:release`. This module
  does NOT reach into the cc agent's snapshot or slices to fabricate a
  respawn — that would violate the plugin contract (§11: no `SnapshotStore` /
  cross-Kind slice reads from plugin code).

  ## Fast curl agent

  Dispatches `curl_agent.configure` with the updated `system_prompt` from
  `provision_context(tid, "fast", source: :release).system_prompt` to all
  live fast curl agents for this tenant. Unlike the slow cc agent, the curl
  agent holds its `system_prompt` in live Kind state, so `configure` updates
  it in place via a `{:set, :system_prompt, _}` effect — no restart needed.

  ## Failure semantics

  Returns `:ok` when CLAUDE.md is written successfully (the content-rewrite is
  the gate). Fast-configure errors are logged as warnings and are non-fatal.
  Returns `{:error, reason}` only on fatal failures (provision fails or
  CLAUDE.md write fails).
  """

  alias EzagentPluginContent.TenantContent

  require Logger

  @doc """
  Refresh agents for tenant `tid` after a publish.

  Rewrites the slow agent's `work_dir/CLAUDE.md` from the new release (read on
  the agent's next start) and updates live fast curl agents' `system_prompt`
  via dispatch.

  Returns `:ok` on success (including degraded-but-non-fatal fast-configure
  errors). Returns `{:error, reason}` on fatal provision or write failures.
  """
  @spec refresh_agents(String.t()) :: :ok | {:error, term()}
  def refresh_agents(tid) when is_binary(tid) do
    with :ok <- refresh_slow(tid) do
      refresh_fast(tid)
    end
  end

  # ---------------------------------------------------------------------------
  # Slow agent refresh: rewrite work-dir CLAUDE.md from the new release.
  # Read by the slow cc agent on its next process start (new session / restart).
  # ---------------------------------------------------------------------------

  defp refresh_slow(tid) do
    case TenantContent.provision_context(tid, "slow", source: :release) do
      {:ok, sctx} ->
        claude_md_path = Path.join(sctx.work_dir, "CLAUDE.md")
        content = sctx.claude_md || ""

        _ = File.mkdir_p(sctx.work_dir)

        case File.write(claude_md_path, content) do
          :ok ->
            Logger.info(
              "Refresh: slow CLAUDE.md rewritten — #{claude_md_path} (#{byte_size(content)} bytes). " <>
                "Live slow agents read it on their next start; a forced hot-restart of a running " <>
                "slow agent is deferred (needs a sanctioned cc respawn dispatch — cc-runtime domain)."
            )

            :ok

          {:error, reason} ->
            {:error, {:slow_claude_md_write_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:slow_provision_failed, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # Fast agent refresh: update system_prompt via curl_agent.configure dispatch.
  # The curl agent holds system_prompt in live Kind state, so this takes effect
  # immediately (no restart) via a {:set, :system_prompt, _} effect.
  # ---------------------------------------------------------------------------

  defp refresh_fast(tid) do
    case TenantContent.provision_context(tid, "fast", source: :release) do
      {:ok, fctx} ->
        new_prompt = fctx.system_prompt

        if is_binary(new_prompt) and byte_size(new_prompt) > 0 do
          dispatch_fast_configure(tid, new_prompt)
        else
          Logger.info("Refresh: fast has no system_prompt in release content, skipping")
          :ok
        end

      {:error, reason} ->
        # Fast refresh is non-fatal: the slow CLAUDE.md rewrite already happened.
        Logger.warning("Refresh: fast provision failed (non-fatal): #{inspect(reason)}")
        :ok
    end
  end

  defp dispatch_fast_configure(tid, new_prompt) do
    # The CurlAgent's `curl_agent.configure` action updates the system_prompt
    # in-place in the live Kind's persistent state (via {:set, :system_prompt, _} effect).
    ctx = %{
      caller: Ezagent.Entity.User.admin_uri(),
      caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
      reply: {:caller_inbox, self()}
    }

    live_fast = live_agents_for(tid, "cs-fast-")

    if live_fast == [] do
      Logger.info("Refresh: no live fast agents for tenant #{tid}, skipping configure dispatch")
    else
      Enum.each(live_fast, fn agent_uri ->
        target =
          Ezagent.URI.new!("#{URI.to_string(agent_uri)}?action=curl_agent.configure")

        result =
          Ezagent.Invocation.dispatch(%Ezagent.Invocation{
            target: target,
            mode: :call,
            args: %{system_prompt: new_prompt},
            ctx: ctx
          })

        case result do
          {:ok, %{ok: true}} ->
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

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Enumerate live entity agents for `tid` whose name starts with `name_prefix`.
  # Uses KindRegistry.list_all/0 — the only available live-listing API.
  defp live_agents_for(tid, name_prefix) do
    Ezagent.KindRegistry.list_all()
    |> Enum.flat_map(fn {uri_str, _pid} ->
      case Ezagent.URI.parse(uri_str) do
        {:ok, %URI{scheme: "entity"} = uri} ->
          case Ezagent.URI.workspace_name(uri) do
            {:ok, ^tid} ->
              case Ezagent.URI.name(uri) do
                {:ok, name} when is_binary(name) ->
                  if String.starts_with?(name, name_prefix), do: [uri], else: []

                _ ->
                  []
              end

            _ ->
              []
          end

        _ ->
          []
      end
    end)
  end
end
