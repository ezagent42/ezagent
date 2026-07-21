defmodule EzagentPluginHello.OfficialSiteSeed do
  @moduledoc """
  Governed deploy-seed for the marketing 官网 — the hello INSTANCE
  `session://system/hello/web` (ruihua "组织的 IDE / Organization IDE" page +
  the front-desk/builder/concierge/curl-`llm` DeepSeek greeter).

  ## Why this exists (and why it is NOT a `manifest.yaml`)

  #1233 moved the *reusable* hello socialware onto the governed
  `priv/socialware_seed/.../manifest.yaml` lane. That lane publishes a
  socialware **Definition** (a template) through `ManifestSeed.scan_all!`; it
  cannot instantiate a session or drive page bytes onto a Surface. The 官网 is
  none of those — it is a concrete **instance**: a specific session
  (`system/hello/web`) with a specific page on its Surface and a DeepSeek
  credential backing its `llm` member. No manifest can carry that.

  So the 官网 needs a code provisioner, and its true precedent is the
  #185/#1478 `EzagentPluginHello.CredentialBridge` — the SAME family of
  governed deploy-seed (config-gated dev/prod, idempotent, deploy-owned, NOT a
  demo flag), living in the plugin's `children/0`, that seeds *instance-level*
  state at boot. This module is the CredentialBridge's instance-layer sibling.
  It deliberately does not touch the `HELLO_DEMO_SEED` demo path
  (`application.ex`, "never seeds in production").

  ## What `ensure/0` does (idempotent, absence-gated, fail-soft)

    1. **Credential first** — `CredentialBridge.ensure_deepseek_source/0`
       (idempotent) so the `"system"` workspace's shared curl credential source
       exists BEFORE the 官网's `llm` member spawns. The `llm` member is born
       with `"deepseek"` in its `:api_keys` slice only if the source is already
       registered at spawn time (see `CredentialBridge` moduledoc), so this
       ordering is what makes the #185 anonymous cold curl-LLM reply work.
       Best-effort: a credential hiccup logs and continues — keyless-spawn stays
       the fallback truth, never a boot failure.

    2. **Absence gate** — provision ONLY when `system/hello/web` has no page.
       A wiped/reseeded deployment has none → self-heal (the whole point). A
       live deployment (including one freshly refreshed by
       `scripts/refresh_hello_site.exs`) keeps its current page untouched, so a
       plain reboot never clobbers a live GitHub-data refresh with the static
       snapshot.

    3. **Provision** — `FusionSeed.run(workspace: @workspace, name: @name)`:
       `App.ensure_app/2` creates the session + seeds the greeter Definition +
       materializes the four role members (front-desk/builder/concierge/`llm`),
       then the committed `priv/seed_page/{body.json,shell.css}` ruihua page is
       driven onto the Surface. Both steps are idempotent.

  Because `ensure/0` runs on every boot and self-heals from absence, the 官网
  survives reseeds: the reseed wipes it, the next boot re-provisions it.

  ## Activation

  The boot Task is `config`-gated (`:ezagent_plugin_hello, :site_seed_boot` —
  dev/prod on via `config/config.exs`, test off via `config/test.exs`, matching
  `:credential_bridge_boot`). Tests call `ensure/0` directly so boot stays
  deterministic and never provisions into the shared `"system"` workspace at
  every test boot.
  """

  require Logger

  alias Ezagent.Entity.User
  alias Ezagent.Socialware.ExternalFeed
  alias EzagentPluginHello.{CredentialBridge, FusionSeed}

  # The 官网 is the `web` hello instance in the `"system"` workspace (07-01:
  # migrated from `site` → `web`; canonical URL `/hello/web`). Compile-time
  # literals — this provisioner has one destination, never a caller-supplied one.
  @workspace "system"
  @name "web"

  @typedoc "Outcome of `ensure/0`."
  @type outcome ::
          {:ok, {:provisioned, URI.t(), String.t()}}
          | {:ok, {:already_provisioned, URI.t()}}
          | {:error, term()}

  @doc "The 官网 session URI (`session://system/hello/web`)."
  @spec site_uri() :: URI.t()
  def site_uri, do: Ezagent.URI.session(@workspace, :hello, @name)

  @doc """
  Should the boot-time 官网 seed Task start? Config-gated (`:site_seed_boot`;
  dev/prod on via `config.exs`, test off via `config/test.exs`).
  """
  @spec boot_enabled?() :: boolean()
  def boot_enabled? do
    Application.get_env(:ezagent_plugin_hello, :site_seed_boot, false)
  end

  @doc """
  Idempotently ensure the 官网 (`system/hello/web`) is provisioned: wire the
  DeepSeek credential source, then (only when the site has no page) instantiate
  the greeter session + drive the ruihua marketing page.

  Returns `{:ok, {:provisioned, uri, turn_id}}` when it drove the page,
  `{:ok, {:already_provisioned, uri}}` when the site already had one (skipped,
  live page preserved), or `{:error, reason}` on a provisioning failure. The
  credential step is best-effort and never turns into an error here.
  """
  @spec ensure() :: outcome()
  def ensure do
    _ = ensure_credential_source()

    case current_page() do
      {:present, uri} -> {:ok, {:already_provisioned, uri}}
      :absent -> provision()
    end
  end

  # --- steps -----------------------------------------------------------------

  # Ensure the "system" workspace shared DeepSeek curl source exists before the
  # 官网's llm member spawns. Best-effort by design (see moduledoc): a failure
  # here must not fail the 官网 — keyless-spawn stays the fallback.
  defp ensure_credential_source do
    case CredentialBridge.ensure_deepseek_source() do
      {:ok, %URI{} = source_uri} ->
        Logger.info(
          "hello official-site seed: deepseek credential source ready at #{URI.to_string(source_uri)}"
        )

        :ok

      {:ok, :no_env_key} ->
        # No DEEPSEEK_API_KEY on this deploy — the 官网 still renders; its
        # greeter stays keyless until an operator wires the key + reseeds.
        :ok

      {:error, reason} ->
        Logger.warning(
          "hello official-site seed: deepseek credential wiring failed: #{inspect(reason)}"
        )

        :ok
    end
  end

  # Absence gate: {:present, uri} when the 官网 already has a rendered page,
  # :absent when it has none (wiped/reseeded, or never provisioned). Reads the
  # cold-safe external projection (durable-snapshot fallback), so a page that
  # survived a plain reboot reads as present and is left untouched.
  defp current_page do
    uri = site_uri()

    case ExternalFeed.snapshot(uri, User.admin_uri()) do
      {:ok, %{page: page}} when not is_nil(page) -> {:present, uri}
      _ -> :absent
    end
  end

  defp provision do
    case FusionSeed.run(workspace: @workspace, name: @name) do
      {:ok, %{session_uri: uri, turn_id: turn_id}} ->
        {:ok, {:provisioned, uri, turn_id}}

      {:error, _reason} = err ->
        err
    end
  end
end
