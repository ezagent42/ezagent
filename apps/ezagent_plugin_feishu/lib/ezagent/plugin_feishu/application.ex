defmodule EzagentPluginFeishu.Application do
  @moduledoc """
  Feishu adapter plugin OTP application — the `Ezagent.Plugin` contract
  module. SPEC v2 §5.8 shape (PR #144).

  ## Plugin authoring contract (PR-3)

  Per the plugin authoring contract SPEC
  (`docs/superpowers/specs/2026-05-22-plugin-authoring-contract.md`,
  §3 / §8 Q3 — Allen confirmed: the OTP `Application` module IS the
  plugin contract module) this module `use`s **both** `Application`
  (OTP plumbing) and `Ezagent.Plugin` (the declarative contract).

  Registration is no longer imperative. `start/2` collapses to
  `Ezagent.Plugin.boot(__MODULE__)`; the framework's two-phase
  `boot/1` reads the declaration callbacks below and performs every
  `*Registry` call — the plugin author never touches a registry API.
  The `:ezagent_plugin_check` Mix compiler (wired into `mix.exs`) is
  the non-bypassable gate that enforces this.

  ## §5.8 — no plugin-owned schemes

  The PR #144 re-shape deleted the `feishu://oc_xxx` Receiver Kind.
  Feishu is the canonical "external integration" plugin: it does NOT
  own a top-level URI scheme — `behaviors/0` registers
  `EzagentPluginFeishu.Behavior.FeishuOutbound` on the **existing**
  `Ezagent.Entity.Session` core Kind, and `spawns/0` keeps the
  `use Ezagent.Plugin` default `[]` (no `feishu` scheme).

  - **Inbound** (Feishu → Ezagent): `InboundDispatcher` resolves
    `sender_open_id → entity://user/<X>` via `FeishuUserBinding` and
    `chat_id → session://<template>/<name>` via the
    `FeishuSessionBinding` join table, then dispatches
    `<session_uri>?action=chat.send` with the message.
  - **Outbound** (Ezagent → Feishu): `Behavior.FeishuOutbound`
    registers against `Ezagent.Entity.Session` for action
    `:notify_external`. `Behavior.Chat.invoke(:send)` opportunistically
    dispatches `notify_external` after fan-out.

  Per `feedback_plugin_external_integration_is_receiver_kind`: any
  future plugin that sends messages out of Ezagent (Slack, Discord,
  email, webhook, …) MUST follow this Behavior-on-existing-Kind
  pattern, NOT introduce a new top-level scheme.

  ## What this plugin declares

  - `behaviors/0` — `{Ezagent.Entity.Session, <action>,
    EzagentPluginFeishu.Behavior.FeishuOutbound}` for every action in
    `FeishuOutbound.actions/0` (the `:notify_external` outbound mirror).
  - `config_surface/0` — `:route` surface. The `/plugins` config icon
    opens the Bindings LiveView at `/plugins/feishu/bindings`.
  - `children/0` — `FeishuChatSupervisor` (a `DynamicSupervisor`,
    retained as a stable name for future intra-plugin processes), the
    `Client` GenServer (Lark token cache + send endpoints), and the
    `WsClient` long-connect (skipped at test boot / `EZAGENT_FEISHU_WS=0`).
  - `after_boot/0` — Phase 3 hook: re-run
    `Ezagent.Workspace.Loader.load_all/0` (Decision #112 boot-ordering)
    and seed any bindings from
    `$EZAGENT_HOME/<profile>/plugins/feishu/initial_bindings.yaml`.
  """

  use Application
  use Ezagent.Plugin
  require Logger

  alias Ezagent.Entity.Session, as: SessionKind
  alias EzagentPluginFeishu.Behavior.FeishuOutbound

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

  # PR #144 SPEC v2 §5.8 — FeishuOutbound registers against the
  # existing `Ezagent.Entity.Session` core Kind for the generic
  # `:notify_external` action. `Ezagent.Behavior.Chat.invoke(:send)`
  # dispatches that action after fan-out (opportunistic — no-op if
  # nothing is registered). NOT a `feishu://` scheme.
  @impl Ezagent.Plugin
  def behaviors do
    for action <- FeishuOutbound.actions() do
      {SessionKind, action, FeishuOutbound}
    end
  end

  @impl Ezagent.Plugin
  def config_surface do
    %{kind: :route, path: "/plugins/feishu/bindings", label: "Bindings"}
  end

  @impl Ezagent.Plugin
  def children do
    [
      {DynamicSupervisor, name: EzagentPluginFeishu.FeishuChatSupervisor, strategy: :one_for_one},
      EzagentPluginFeishu.Client,
      # PR-C of Presence rollout (SPEC `docs/superpowers/specs/2026-05-23-presence.md`
      # rev 3 §7) — mirrors Feishu-bound user activity into
      # `Ezagent.Presence` as `:transport => :feishu`. Singleton; tracked
      # entries persist for the duration of THIS process (Application
      # lifetime). `InboundDispatcher.dispatch/1` casts `touch/1` after
      # successful sender resolution.
      EzagentPluginFeishu.PresenceMirror,
      # Phase 6 PR 15: WS long-connect to Feishu. Skipped at test boot
      # (Mix.env() == :test) and when EZAGENT_FEISHU_WS=0 (operator opt-out).
      maybe_ws_client_spec()
    ]
    |> Enum.reject(&is_nil/1)
  end

  # Phase 3 post-register hook. Decision #112 boot-ordering: re-run the
  # workspace loader once FeishuOutbound is published (Phase 2). Then
  # seed initial bindings (skipped in test env — see seed_initial_bindings/0).
  @impl Ezagent.Plugin
  def after_boot do
    _ = Ezagent.Workspace.Loader.load_all()
    :ok = seed_initial_bindings()
    :ok
  end

  # --- internals ------------------------------------------------------

  defp maybe_ws_client_spec do
    if Mix.env() == :test do
      nil
    else
      EzagentPluginFeishu.WsClient
    end
  end

  defp seed_initial_bindings do
    # Hotfix carried over from PR #133: skip in test env so the test
    # suite doesn't leak real network calls to Feishu (boot-seeded
    # subscribers forwarded test messages to real chats — Allen
    # observed this 2026-05-17).
    if Mix.env() == :test do
      :ok
    else
      do_seed_initial_bindings()
    end
  end

  defp do_seed_initial_bindings do
    file = Path.join([Ezagent.Home.path(:plugins), "feishu", "initial_bindings.yaml"])

    case File.read(file) do
      {:ok, body} ->
        case YamlElixir.read_from_string(body) do
          {:ok, %{"bindings" => bindings}} when is_list(bindings) ->
            seed_each(bindings)

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp seed_each(bindings) do
    Enum.each(bindings, fn binding ->
      chat_id = Map.get(binding, "chat_id")
      target_session = Map.get(binding, "session_uri") || "session://default/default/main"

      if is_binary(chat_id) and chat_id != "" do
        Logger.info(
          "Feishu plugin: seeding initial binding chat_id=#{chat_id} → #{target_session}"
        )

        case EzagentPluginFeishu.SessionBinding.bind(chat_id, target_session) do
          {:ok, _row} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "Feishu plugin: initial binding chat_id=#{chat_id} failed: #{inspect(reason)}"
            )
        end
      end
    end)

    :ok
  end
end
