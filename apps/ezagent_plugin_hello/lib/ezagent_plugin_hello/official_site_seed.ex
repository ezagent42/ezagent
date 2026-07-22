defmodule EzagentPluginHello.OfficialSiteSeed do
  @moduledoc """
  Governed deploy-seed for the marketing 官网 — the hello INSTANCE
  `session://<home>/hello/ezagent-official` (ruihua "组织的 IDE / Organization
  IDE" page + the front-desk/builder/concierge/curl-`llm` DeepSeek greeter),
  where `<home>` is the hello home workspace
  (`EzagentPluginHello.home_workspace/0`, default `"ezagent"`).

  ## hello-A (2026-07-22): the 官网 is an ezagent-member session, not a system singleton

  The 官网 used to be pinned to the `system` workspace (`system/hello/web`),
  which made `caller_ws=ezagent ≠ target_ws=system` for every real user and
  tripped the cross-workspace isolation denial. It is now a NORMAL session in
  the home workspace, created by mimicking an ezagent-workspace MEMBER:

    * **Owner** = the home workspace's founder (`created_by` from the workspace
      store), resolved BEFORE any seed-side `Workspace.create` (the credential
      bridge creates the home workspace admin-owned when absent — resolving
      after would misread THAT as the founder). A missing OR system-admin
      `created_by` falls back to `entity://<home>/user/lin_yilun` — NEVER
      `entity://system/user/admin`.
    * With session-ws == owner-ws == users-ws == `ezagent`, the isolation check
      passes at `ws_equal?` with ZERO cap-machinery change.
    * The reusable socialware Definition/template publish lane stays in
      `system` (platform-admin namespace) — only the INSTANCE moved.

  ## Why this exists (and why it is NOT a `manifest.yaml`)

  #1233 moved the *reusable* hello socialware onto the governed
  `priv/socialware_seed/.../manifest.yaml` lane. That lane publishes a
  socialware **Definition** (a template) through `ManifestSeed.scan_all!`; it
  cannot instantiate a session or drive page bytes onto a Surface. The 官网 is
  none of those — it is a concrete **instance**: a specific session
  (`<home>/hello/ezagent-official`) with a specific page on its Surface and a
  DeepSeek credential backing its `llm` member. No manifest can carry that.

  So the 官网 needs a code provisioner, and its true precedent is the
  #185/#1478 `EzagentPluginHello.CredentialBridge` — the SAME family of
  governed deploy-seed (config-gated dev/prod, idempotent, deploy-owned, NOT a
  demo flag), living in the plugin's `children/0`, that seeds *instance-level*
  state at boot. This module is the CredentialBridge's instance-layer sibling.
  It deliberately does not touch the `HELLO_DEMO_SEED` demo path
  (`application.ex`, "never seeds in production").

  ## What `ensure/0` does (idempotent, absence-gated, fail-soft)

    1. **Owner first** — resolve the 官网 owner (above) BEFORE anything may
       create the home workspace.

    2. **Credential** — `CredentialBridge.ensure_deepseek_source/0`
       (idempotent) so the home workspace's shared curl credential source
       exists BEFORE the 官网's `llm` member spawns. The `llm` member is born
       with `"deepseek"` in its `:api_keys` slice only if the source is already
       registered at spawn time (see `CredentialBridge` moduledoc), so this
       ordering is what makes the #185 anonymous cold curl-LLM reply work.
       Best-effort: a credential hiccup logs and continues — keyless-spawn stays
       the fallback truth, never a boot failure.

    3. **Absence gate** — provision ONLY when `<home>/hello/ezagent-official`
       has no page. A wiped/reseeded deployment has none → self-heal (the whole
       point). A live deployment (including one freshly refreshed by
       `scripts/refresh_hello_site.exs`) keeps its current page untouched, so a
       plain reboot never clobbers a live GitHub-data refresh with the static
       snapshot.

    4. **Provision** — `FusionSeed.run(workspace: <home>, name: @name, owner:
       owner)`: `App.ensure_app/3` creates the session (owned by the home
       founder) + seeds the greeter Definition + materializes the role members
       (front-desk/builder/concierge/`llm`/…), then the committed
       `priv/seed_page/{body.json,shell.css}` ruihua page is driven onto the
       Surface AS THE OWNER. All steps are idempotent.

  Because `ensure/0` runs on every boot and self-heals from absence, the 官网
  survives reseeds: the reseed wipes it, the next boot re-provisions it.

  ## Activation

  The boot Task is `config`-gated (`:ezagent_plugin_hello, :site_seed_boot` —
  dev/prod on via `config/config.exs`, test off via `config/test.exs`, matching
  `:credential_bridge_boot`). Tests call `ensure/0` directly so boot stays
  deterministic and never provisions into the shared home workspace at every
  test boot.
  """

  require Logger

  alias Ezagent.Entity.User
  alias Ezagent.Socialware.ExternalFeed
  alias EzagentPluginHello.{CredentialBridge, FusionSeed}

  # The 官网 is the `ezagent-official` hello instance in the hello HOME
  # workspace (hello-A: migrated from `system/hello/web`; canonical URL
  # `/hello/ezagent-official`). The workspace comes from the SINGLE config
  # source (`EzagentPluginHello.home_workspace/0`), read at runtime.
  @name "ezagent-official"
  @fallback_owner_name "lin_yilun"

  @typedoc "Outcome of `ensure/0`."
  @type outcome ::
          {:ok, {:provisioned, URI.t(), String.t()}}
          | {:ok, {:already_provisioned, URI.t()}}
          | {:error, term()}

  @doc "The 官网 session URI (`session://<home>/hello/ezagent-official`)."
  @spec site_uri() :: URI.t()
  def site_uri, do: Ezagent.URI.session(EzagentPluginHello.home_workspace(), :hello, @name)

  @doc """
  Should the boot-time 官网 seed Task start? Config-gated (`:site_seed_boot`;
  dev/prod on via `config.exs`, test off via `config/test.exs`).
  """
  @spec boot_enabled?() :: boolean()
  def boot_enabled? do
    Application.get_env(:ezagent_plugin_hello, :site_seed_boot, false)
  end

  @doc """
  Idempotently ensure the 官网 (`<home>/hello/ezagent-official`) is
  provisioned: resolve the owner, wire the DeepSeek credential source, then
  (only when the site has no page) instantiate the greeter session + drive the
  ruihua marketing page as the owner.

  Returns `{:ok, {:provisioned, uri, turn_id}}` when it drove the page,
  `{:ok, {:already_provisioned, uri}}` when the site already had one (skipped,
  live page preserved), or `{:error, reason}` on a provisioning failure. The
  credential step is best-effort and never turns into an error here.
  """
  @spec ensure() :: outcome()
  def ensure do
    # Resolve the 官网 owner BEFORE any seed-side `Workspace.create` — the
    # credential step below creates the home workspace ADMIN-owned when it is
    # absent, and resolving after that would misread the admin as the founder.
    owner = resolve_owner()
    _ = ensure_credential_source()

    case current_page() do
      {:present, uri} -> {:ok, {:already_provisioned, uri}}
      :absent -> provision(owner)
    end
  end

  # --- steps -----------------------------------------------------------------

  # The 官网 owner = the home workspace's founder (`created_by`). The owner
  # must LIVE in the home workspace ("seed as an ezagent MEMBER") — a founder
  # recorded OUTSIDE it (notably `entity://system/user/admin`, written when
  # the credential bridge auto-creates the home workspace) can never be a
  # home-workspace member and is treated as "no valid founder", falling back
  # to `entity://<home>/user/lin_yilun` (a real ezagent-workspace user with
  # admin privileges) — NEVER a `system`-workspace principal (that would
  # re-introduce the system/ezagent owner mismatch hello-A removes). This is
  # a workspace-shape precondition on seed input, not an authorization check
  # (authz stays at the dispatch chokepoint).
  defp resolve_owner do
    home = EzagentPluginHello.home_workspace()

    case Ezagent.Workspace.Store.get_by_name(home) do
      %{created_by: %URI{} = founder} ->
        if Ezagent.Capability.workspace_of(founder) == Ezagent.URI.workspace(home) do
          founder
        else
          fallback_owner(
            home,
            "founder #{URI.to_string(founder)} is not a home-workspace principal"
          )
        end

      _no_row_or_no_founder ->
        fallback_owner(home, "no founder recorded")
    end
  end

  defp fallback_owner(home, reason) do
    owner = Ezagent.URI.entity(home, :user, @fallback_owner_name)

    Logger.info(
      "hello official-site seed: #{reason} for workspace #{inspect(home)} — " <>
        "official-site owner falls back to #{URI.to_string(owner)}"
    )

    owner
  end

  # Ensure the home workspace's shared DeepSeek curl source exists before the
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

  defp provision(owner) do
    case FusionSeed.run(
           workspace: EzagentPluginHello.home_workspace(),
           name: @name,
           owner: owner
         ) do
      {:ok, %{session_uri: uri, turn_id: turn_id}} ->
        {:ok, {:provisioned, uri, turn_id}}

      {:error, _reason} = err ->
        err

      other ->
        # The provision chain can leak non-2-tuple shapes (observed: the
        # socialware-install transaction's `{:error, reason, partial}`
        # 3-tuple riding a `with` passthrough on a founder-less blank
        # stack). The seed is fail-SOFT by contract — normalize instead of
        # crashing the one-shot boot Task with a CaseClauseError.
        {:error, {:unexpected_seed_result, other}}
    end
  end
end
