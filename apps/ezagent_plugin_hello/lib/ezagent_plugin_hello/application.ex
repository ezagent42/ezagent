defmodule EzagentPluginHello.Application do
  @moduledoc """
  Hello plugin OTP application — the `Ezagent.Plugin` contract module.

  `hello` is an app where an AI **builder agent generates a UI page** (as a
  structured `@json-render` spec, constrained by a Zod component catalog), the
  page is **born only via `Behavior.Surface.put_version/2`** (driven by
  `Behavior.Turn`), and **anonymous external visitors view it** through the
  socialware substrate (`public_view` SessionTemplate → `ExternalFeed` →
  `/socialware/chat`). It is the modern re-implementation of the retired `loom`
  experiment, built fresh on `main`. See
  `docs/superpowers/handoffs/2026-06-22-loom-to-hello-migration-claude-to-dev-handoff.md`.

  ## Plugin authoring contract

  Per the plugin authoring contract, the OTP `Application` module IS the plugin
  contract module: it `use`s both `Application` (OTP plumbing) and
  `Ezagent.Plugin` (the declarative contract). `start/2` collapses to
  `Ezagent.Plugin.boot(__MODULE__)`; the framework reads the declaration
  callbacks and performs every `*Registry` call — the author never touches a
  registry API. The `:ezagent_plugin_check` Mix compiler is the non-bypassable
  gate.

  ## Phase 0 scaffold (this commit)

  Only `plugin_info/0` is declared so far — a minimal, compilable, gate-passing
  plugin shell. The builder agent (`template_classes/0` + `agent_flavors/0`), the
  internal `PageView` registration, and the Turn/Surface generation wiring land
  in the following Phase-0 steps (0.2–0.5). Every other `Ezagent.Plugin`
  callback keeps its `use`-macro default (`[]` / `nil` / `:ok`).
  """

  use Application
  use Ezagent.Plugin

  require Logger

  @impl Application
  def start(_type, _args) do
    result = Ezagent.Plugin.boot(__MODULE__)
    # Register the internal @json-render page view (un-degrades the console's
    # render of a hello session). The registry is init'd by ezagent_domain_ui,
    # which boots before this plugin (a declared dep).
    _ = Ezagent.UI.SessionViewRegistry.register(EzagentPluginHello.PageView)

    # NOTE: the hello DEMO socialware is NOT published here. It ships as a
    # deploy-seed package (`apps/ezagent_web/priv/socialware_seed/hello/
    # manifest.yaml`, like `autoservice`): `Ezagent.Home.SocialwareSeed` copies
    # it into the deployment home and the late boot scan
    # `Ezagent.Socialware.ManifestSeed.scan_all!/1` (run from the last-booting
    # transport app, AFTER this plugin registered its PageView + `hello_render`
    # cap so `uses: ["hello"]` resolves) publishes it through the governed
    # import lane. Zero call from this plugin's boot; `Ezagent.Socialware.Demo.Hello`
    # remains only as a test driver (deploy-seed SPEC §2/§4).
    result
  end

  # Phase 2 — register the `session.hello` Template Class so a hello app is
  # creatable through the substrate's generic Tier-3 create path (the one world's
  # internal console drives via `session.create`). No world edit — world creates
  # any registered session type generically.
  @impl Ezagent.Plugin
  def template_classes, do: [EzagentPluginHello.Template.HelloSession]

  # The `"hello"` agent FLAVOR — the host for hello's role agents that must RECEIVE
  # chat and run custom Elixir (the orchestrator). Its in-process AgentBridge
  # adapter (`BridgeAdapter`) is the seam `Agent.Receive` routes chat into; `native`
  # has no adapter, so a native agent's chat is dropped. `cap_policy` reuses native's
  # recipe-scoped fail-closed policy (mints exactly the role's requested caps).
  @impl Ezagent.Plugin
  def agent_flavors do
    [
      %{
        flavor: "hello",
        kind: Ezagent.Entity.Agent,
        instance_behaviors: fn ->
          Ezagent.Entity.Agent.base_behaviors() ++ [Ezagent.ActionSet.HelloOrchestrator]
        end,
        template_class: EzagentPluginHello.Template.HelloAgent,
        bridge_adapter: EzagentPluginHello.BridgeAdapter,
        cap_policy: &EzagentPluginNative.CapPolicy.for_recipe/1
      }
    ]
  end

  # hello's two agents are ROLES on the unified `Entity.Agent` (hosted by the
  # `native` flavor), NOT own Kinds (Principle 1: an agent type is a role × flavor,
  # never its own Kind). The behaviors load PER-INSTANCE via the recipe (RF-1
  # `BehaviorSet.resolve_action` on `Entity.Agent`); cold-restart revival re-reads
  # the durable `:role` marker from the sandbox slice and re-composes — so no
  # `agent_flavors`/own-Kind revival registration is needed. Not `passive`: the
  # builder/concierge are chat principals (@-mentionable + joinable).
  @impl Ezagent.Plugin
  def roles,
    do: [
      hello_front_desk_recipe(),
      hello_builder_recipe(),
      hello_concierge_recipe(),
      hello_llm_recipe(),
      hello_sharer_recipe(),
      hello_publisher_recipe(),
      hello_dispatcher_recipe()
    ]

  @doc "The `hello.front-desk` role — the invisible per-session chat relay that dispatches to builder/concierge via their dispatchable actions."
  @spec hello_front_desk_recipe() :: map()
  def hello_front_desk_recipe do
    %{
      name: "hello.front-desk",
      behaviors: [Ezagent.ActionSet.HelloOrchestrator],
      requested_caps: [
        %{behavior: Ezagent.ActionSet.HelloOrchestrator, action: :hello_sync_result}
      ]
    }
  end

  @doc "The `hello.builder` role — the page-generating agent (`Behavior.HelloBuilder`)."
  @spec hello_builder_recipe() :: map()
  def hello_builder_recipe do
    %{
      name: "hello.builder",
      behaviors: [Ezagent.ActionSet.HelloBuilder],
      requested_caps: [
        %{behavior: Ezagent.ActionSet.HelloBuilder, action: :receive},
        %{behavior: Ezagent.ActionSet.HelloBuilder, action: :rebuild}
      ]
    }
  end

  @doc "The `hello.concierge` role — the read-only Q&A/navigation agent (`Behavior.HelloConcierge`)."
  @spec hello_concierge_recipe() :: map()
  def hello_concierge_recipe do
    %{
      name: "hello.concierge",
      behaviors: [Ezagent.ActionSet.HelloConcierge],
      requested_caps: [
        %{behavior: Ezagent.ActionSet.HelloConcierge, action: :receive},
        %{behavior: Ezagent.ActionSet.HelloConcierge, action: :answer}
      ]
    }
  end

  @doc "The `hello.llm` role — a flavor-selected platform agent Hello delegates generation to (credential-optional so the platform credential cascade decides readiness)."
  @spec hello_llm_recipe() :: map()
  def hello_llm_recipe do
    %{
      name: "hello.llm",
      # The selected flavor supplies its own instance behaviors; this recipe
      # supplies only generic role configuration.
      config: %{
        credential_optional: true
      },
      requested_caps: []
    }
  end

  @doc "The `hello.sharer` role — wraps 'create share link' as a dispatchable action (`Behavior.HelloSharer`)."
  @spec hello_sharer_recipe() :: map()
  def hello_sharer_recipe do
    %{
      name: "hello.sharer",
      behaviors: [Ezagent.ActionSet.HelloSharer],
      requested_caps: [%{behavior: Ezagent.ActionSet.HelloSharer, action: :share}]
    }
  end

  @doc "The `hello.publisher` role — wraps 'publish as template' as a dispatchable action (`Behavior.HelloPublisher`)."
  @spec hello_publisher_recipe() :: map()
  def hello_publisher_recipe do
    %{
      name: "hello.publisher",
      behaviors: [Ezagent.ActionSet.HelloPublisher],
      requested_caps: [%{behavior: Ezagent.ActionSet.HelloPublisher, action: :publish}]
    }
  end

  @doc "The `hello.dispatcher` role — delegates an authenticated hello instruction to the workspace Kanban."
  @spec hello_dispatcher_recipe() :: map()
  def hello_dispatcher_recipe do
    %{
      name: "hello.dispatcher",
      behaviors: [Ezagent.ActionSet.HelloDispatcher],
      requested_caps: [
        %{behavior: Ezagent.ActionSet.HelloDispatcher, action: :delegate_to_kanban}
      ]
    }
  end

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "hello",
      name: "Hello",
      description: "AI-generated UI pages (@json-render) on the socialware substrate.",
      version: "0.1.0"
    }
  end

  # Under the role model, hello's chat behaviors load PER-INSTANCE via the recipes
  # (`roles/0`) on the generic `Entity.Agent` host — NOT via static `behaviors/0`
  # rows on the now-deleted `Entity.HelloBuilder`/`HelloConcierge` Kinds. The only
  # remaining static binding is the T2-2a view-render cap subject below.
  @impl Ezagent.Plugin
  def behaviors do
    # T2-2a — register the hello view read ActionSet's `<sw>_render` action on the
    # Session Kind. Cap-only (dispatchable? false) so this writes only the
    # `{Session, :hello_render}` cap subject; there is no dispatch route. This is the
    # cap `authorize_view/3` (T2-2b) checks for a hello page view.
    [
      {Ezagent.Entity.Session, :hello_render, Ezagent.ActionSet.HelloRender}
    ]
  end

  # The supervisor for off-process page-generation Tasks (the LLM round-trip),
  # the #185 env→curl credential bridge (env-gated; no-op without
  # `DEEPSEEK_API_KEY`), the governed 官网 (`<home>/hello/ezagent-official`)
  # deploy-seed (config-gated, dev/prod), plus an OPT-IN demo boot seed (off by
  # default).
  @impl Ezagent.Plugin
  def children do
    [
      {Registry, keys: :unique, name: EzagentPluginHello.CompletionRegistry},
      {Task.Supervisor, name: EzagentPluginHello.TaskSupervisor}
    ] ++
      official_site_children() ++ demo_seed_children() ++ migrate_children()
  end

  defp official_site_children do
    if EzagentPluginHello.OfficialSiteSeed.boot_enabled?() do
      [
        Supervisor.child_spec({Task, &run_official_site_seed/0},
          id: :hello_official_site_seed,
          restart: :transient
        )
      ]
    else
      []
    end
  end

  defp run_official_site_seed do
    # Let the session / socialware / identity supervisors settle before driving a
    # Turn (same rationale as the demo seed). Credential ordering is NOT carried
    # by this delay — `OfficialSiteSeed.ensure/0` ensures the DeepSeek source
    # itself as its first step, so the `llm` member is born credentialed
    # regardless of how the standalone credential-bridge child is scheduled.
    Process.sleep(3_000)

    case EzagentPluginHello.OfficialSiteSeed.ensure() do
      {:ok, {:already_provisioned, uri}} ->
        Logger.info(
          "hello official-site seed: #{URI.to_string(uri)} already provisioned — skipped"
        )

      {:ok, {:provisioned, uri, turn_id}} ->
        Logger.info(
          "hello official-site seed: provisioned #{URI.to_string(uri)} (turn #{turn_id}) — open /hello/ezagent-official"
        )

      {:error, reason} ->
        Logger.warning("hello official-site seed failed: #{inspect(reason)}")
    end
  end

  # `HELLO_MIGRATE_ORCHESTRATOR=1` → at boot (once the substrate settles), give every
  # EXISTING hello session the orchestrator front desk it predates
  # (`EzagentPluginHello.Migrate`). Idempotent + best-effort; a one-shot transient
  # Task so it never blocks the supervisor. OFF by default.
  defp migrate_children do
    if System.get_env("HELLO_MIGRATE_ORCHESTRATOR") in ["1", "true"] do
      [
        Supervisor.child_spec({Task, &run_orchestrator_migration/0},
          id: :hello_migrate,
          restart: :transient
        )
      ]
    else
      []
    end
  end

  defp run_orchestrator_migration do
    # Let the session / socialware / identity supervisors settle before reviving +
    # joining across sessions.
    Process.sleep(5_000)
    report = EzagentPluginHello.Migrate.migrate_all()

    migrated = Map.get(report, :migrated, [])
    skipped = Map.get(report, :skipped, [])
    failed = Map.get(report, :failed, [])

    Logger.info(
      "hello orchestrator migration done — migrated=#{length(migrated)} " <>
        "skipped=#{length(skipped)} failed=#{length(failed)}"
    )

    if failed != [], do: Logger.warning("hello migration failures: #{inspect(failed)}")
  end

  # `HELLO_DEMO_SEED=1` → at boot, instantiate a `public_view` hello app and land
  # a seed page IN THIS NODE, so an anonymous visitor can immediately see a
  # rendered page at `/socialware/chat` (the cross-BEAM `mix ezagent.demo.seed_hello`
  # cannot, since the running server does not auto-revive another node's session).
  # OFF by default — never seeds in production. One-shot transient Task so it
  # never blocks the supervisor; a failure is logged, not fatal.
  defp demo_seed_children do
    if System.get_env("HELLO_DEMO_SEED") in ["1", "true"] do
      [Supervisor.child_spec({Task, &demo_seed/0}, id: :hello_demo_seed, restart: :transient)]
    else
      []
    end
  end

  defp demo_seed do
    # Let the substrate (session/socialware/identity supervisors) settle before
    # driving a Turn.
    Process.sleep(3_000)
    ws = System.get_env("HELLO_DEMO_WS") || "demo"
    name = System.get_env("HELLO_DEMO_NAME") || "main"

    _ =
      case Ezagent.Workspace.create(ws, %{}) do
        {:ok, _} -> :ok
        {:error, _} -> :ok
      end

    case EzagentPluginHello.App.ensure_app(ws, name) do
      {:ok, session_uri, _builder} ->
        _ = seed_or_generate(session_uri)
        log_ready(session_uri)

      other ->
        Logger.warning("hello demo seed failed: #{inspect(other)}")
    end
  end

  # Log both anon view URLs:
  #   * /socialware/external — the membership-authorized ExternalFeed (what the
  #     integration test proves); an anonymous visitor is minted a read-only
  #     anon-User and joined, so it opens with no login.
  #   * /socialware/chat — the chat-feed surface (anon self-serve via membership).
  defp log_ready(session_uri) do
    s = URI.to_string(session_uri)

    Logger.info("""
    hello demo seed ready — open as an anonymous visitor (public_view, no login —
    a read-only anon-User is minted + joined; the ExternalFeed renders the approved generated page):
      /socialware/external?session_uri=#{s}
    """)
  end

  # With `HELLO_DEMO_PROMPT` set, do a REAL builder generation (LLM →
  # catalog-validated spec → Surface) so the page is genuinely AI-built; on any
  # failure (no key / network / out-of-catalog output) fall back to the static
  # seed so the surface is never empty. Without the prompt, just the static seed.
  defp seed_or_generate(session_uri) do
    case System.get_env("HELLO_DEMO_PROMPT") do
      prompt when is_binary(prompt) and prompt != "" ->
        case EzagentPluginHello.App.generate_now(session_uri, prompt) do
          {:ok, _turn} ->
            Logger.info("hello demo: generated a page for prompt #{inspect(prompt)}")

          other ->
            Logger.warning("hello demo: LLM generate failed (#{inspect(other)}); using seed")
            seed_page(session_uri)
        end

      _ ->
        seed_page(session_uri)
    end
  end

  defp seed_page(session_uri) do
    case EzagentPluginHello.FusionSeed.apply_to(session_uri) do
      {:ok, turn_id} ->
        Logger.info("hello seed_page: applied complete Fusion website (turn #{turn_id})")

      {:error, reason} ->
        Logger.warning("hello seed_page failed: #{inspect(reason)}")
    end
  end
end
