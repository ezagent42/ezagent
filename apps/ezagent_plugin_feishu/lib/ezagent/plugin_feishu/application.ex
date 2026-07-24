defmodule EzagentPluginFeishu.Application do
  @moduledoc """
  Feishu adapter plugin OTP application — the `Ezagent.Plugin` contract
  module.

  ## PR-EM-6 reshape (SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`)

  PR-EM-6 retires the one-off Feishu outbound path
  (`EzagentPluginFeishu.Behavior.FeishuOutbound` +
  `EzagentPluginFeishu.SessionBinding`) and replaces it with the
  generic ExternalMirror Domain contract:

  - **Adapter / Binding pair** declared via the new
    `Ezagent.Plugin.adapters/0` callback. The pair is
    `{EzagentPluginFeishu.FeishuAdapter, EzagentPluginFeishu.FeishuChatBinding}`
    — Grill-5 enforces bidirectional declaration at compile time.
  - **Per-adapter cap (Cap 2)** is a marker Behavior
    `EzagentPluginFeishu.Behavior.ExternalAdapter.Feishu.Allow` (cap-only,
    `dispatchable?/0 == false`), registered against
    `Ezagent.Entity.Session` for action `:allow_feishu` so the bind
    facade's Check 2 can match against it.
  - **No more `:notify_external`** registration — outbound chat fan-out
    now flows generically: Session Publisher → per-binding Worker Kind
    → Adapter.event_to_payload/1 → Binding.publish/2 (per SPEC §2.4).
  - **Inbound side-channel** (Feishu webhook → Ezagent session) still uses
    `EzagentPluginFeishu.InboundDispatcher` but reads from the generic
    `external_mirror_bindings` table via
    `EzagentPluginFeishu.InboundChatLookup.resolve/1` instead of the
    retired `EzagentPluginFeishu.SessionBinding.resolve/1`.

  ## Plugin authoring contract

  Per `docs/superpowers/specs/2026-05-22-plugin-authoring-contract.md`,
  this module `use`s both `Application` (OTP plumbing) and
  `Ezagent.Plugin` (the declarative contract). `start/2` collapses to
  `Ezagent.Plugin.boot(__MODULE__)`; the framework's two-phase
  `boot/1` reads the declaration callbacks below and performs every
  `*Registry` call — the plugin author never touches a registry API.

  ## What this plugin declares (post-PR-EM-6)

  - `adapters/0` — `{FeishuAdapter, FeishuChatBinding}` for the
    generic ExternalMirror outbound path.
  - `behaviors/0` — `{Ezagent.Entity.Session, :allow_feishu,
    Behavior.ExternalAdapter.Feishu.Allow}` for the per-adapter cap
    marker (Cap 2). No more FeishuOutbound `:notify_external`
    registration.
  - `config_surface/0` — `:route` surface at
    `/plugins/feishu/bindings` (user bindings only post-PR-EM-6;
    session bindings moved to the generic admin LV from PR-EM-4).
  - `children/0` — `FeishuChatSupervisor`, `Client`, `PresenceMirror`,
    and (non-test) `WsClient`.
  - `after_boot/0` — re-run `Workspace.Loader.load_all/0` (Decision
    #112 boot-ordering) and seed any initial user bindings.
  """

  use Application
  use Ezagent.Plugin
  require Logger

  alias Ezagent.Entity.Session, as: SessionKind
  alias Ezagent.Entity.Workspace, as: WorkspaceKind
  alias EzagentPluginFeishu.{FeishuAdapter, FeishuChatBinding}
  alias EzagentPluginFeishu.Behavior.ExternalAdapter.Feishu.Allow, as: FeishuAllow
  alias EzagentPluginFeishu.Behavior.UserBinding, as: UserBindingBehavior

  # --- OTP Application -------------------------------------------------

  @impl Application
  def start(_type, _args), do: Ezagent.Plugin.boot(__MODULE__)

  # --- Ezagent.Plugin contract ---------------------------------------

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "feishu",
      name: "Feishu (Lark)",
      description: "Lark integration (inbound webhook + outbound bot).",
      version: "0.1.0"
    }
  end

  # PR-EM-6: the only Session-Kind Behavior the plugin registers is
  # the per-adapter Cap 2 marker (`:allow_feishu`). The retired
  # `FeishuOutbound` `:notify_external` registration is gone — chat
  # fan-out flows generically via Session Publisher → ExternalMirror
  # Worker → FeishuChatBinding (SPEC §2.4).
  #
  # PR cli-lv-parity (HIGH-2): also register
  # `EzagentPluginFeishu.Behavior.UserBinding` on Workspace Kind so
  # the legacy `mix ezagent.feishu.bind/unbind/list` triplet has a
  # dispatch-backed `mix ezagent workspace bind/unbind/list_feishu_bindings`
  # equivalent. Each action goes through `Ezagent.Invocation.dispatch/1`
  # → step 5.5 cap check via `required_caps/0` (PR-CC-2-v2). No
  # FacadeRegistry shortcut per codex PR #304 r1 HIGH.
  @impl Ezagent.Plugin
  def behaviors do
    session_behaviors =
      for action <- FeishuAllow.actions() do
        {SessionKind, action, FeishuAllow}
      end

    user_binding_behaviors =
      for action <- UserBindingBehavior.actions() do
        {WorkspaceKind, action, UserBindingBehavior}
      end

    session_behaviors ++ user_binding_behaviors
  end

  # PR-EM-6 (SPEC §5.1 + §9 PR-EM-6) — declare the generic ExternalMirror
  # Adapter/Binding pair. `Ezagent.Plugin.boot/1` enforces Grill-5
  # (adapter + binding implement their behaviours, bidirectional
  # match, distinct modules) and registers both with
  # AdapterRegistry + BindingRegistry. The per-adapter cap subject is
  # automatically registered via `AdapterInstall.install/1` once the
  # adapter is in AdapterRegistry (PR-EM-3 r2 HIGH-3 fix).
  @impl Ezagent.Plugin
  def adapters, do: [{FeishuAdapter, FeishuChatBinding}]

  @impl Ezagent.Plugin
  def config_surface do
    %{kind: :route, path: "/plugins/feishu/bindings", label: "Bindings"}
  end

  @impl Ezagent.Plugin
  def children do
    [
      {DynamicSupervisor, name: EzagentPluginFeishu.FeishuChatSupervisor, strategy: :one_for_one},
      EzagentPluginFeishu.Client,
      # PR-C of Presence rollout — mirrors Feishu-bound user activity
      # into `Ezagent.Presence` as `:transport => :feishu`.
      EzagentPluginFeishu.PresenceMirror,
      # WS long-connect to Feishu. Skipped at test boot (Mix.env() == :test)
      # and when EZAGENT_FEISHU_WS=0 (operator opt-out).
      maybe_ws_client_spec()
    ]
    |> Enum.reject(&is_nil/1)
  end

  # Phase 3 post-register hook. Decision #112 boot-ordering: re-run the
  # workspace loader once Behaviors + Adapters are published, then seed
  # initial USER bindings (open_id → user_uri) via the strict importer
  # (handoff B1) which routes every mutation through formal synchronous
  # dispatch — CapBAC, workspace check, anti-hijack, BindingPolicy, and
  # deterministic rollback. The legacy raw-storage seed (open_id logged
  # in full, `:ok` on every parse/validation error, unconditional upsert
  # without workspace scoping) is retired.
  @impl Ezagent.Plugin
  def after_boot do
    _ = Ezagent.Workspace.Loader.load_all()
    :ok = seed_initial_user_bindings()
    :ok
  end

  # --- internals ------------------------------------------------------

  defp maybe_ws_client_spec do
    if Code.ensure_loaded?(Mix) and Mix.env() == :test do
      nil
    else
      EzagentPluginFeishu.WsClient
    end
  end

  defp seed_initial_user_bindings do
    # Handoff B1 Phase 2 — the importer (not this Application module)
    # owns the parse → preflight → dispatch pipeline. This function
    # only resolves the seed path and delegates.
    plugins_dir = Ezagent.System.FsResolver.path!(Ezagent.URI.system_principal("plugins"))
    file = Path.join([plugins_dir, "feishu", "initial_user_bindings.yaml"])

    case EzagentPluginFeishu.UserBindingSeed.run(file) do
      {:ok, :absent} ->
        :ok

      {:ok, %{bound: bound, same: same, total: total}} ->
        Logger.info(
          "Feishu plugin: seeded #{length(bound)} new, #{length(same)} " <>
            "already-current of #{total} user binding rows"
        )

        :ok

      {:error, :seed_not_enabled} ->
        raise "Feishu plugin: initial user binding seed file is present, " <>
                "but seed is not enabled. Set `config :ezagent_plugin_feishu, :seed_enabled, true` " <>
                "after auth integration (deferred)."

      {:error, :seed_executor_not_configured} ->
        raise "Feishu plugin: initial user binding seed file is present, but seed " <>
                "executor/boot authorization is not configured. The deferred B-layer " <>
                "auth integration must be configured before enabling this seed."

      {:error, {:invalid_seed_executor_port, fields}} ->
        raise "Feishu plugin: initial user binding seed executor port is invalid for " <>
                "#{inspect(fields)}. Configure arity-1 `list_current` and arity-3 `bind` functions."

      {:error, reason} ->
        raise "Feishu plugin: initial user binding seed failed: " <>
                "#{EzagentPluginFeishu.Redact.describe(reason)}"
    end
  end
end
