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
    result
  end

  # Phase 2 — register the `session.hello` Template Class so a hello app is
  # creatable through the substrate's generic Tier-3 create path (the one world's
  # internal console drives via `session.create`). No world edit — world creates
  # any registered session type generically.
  @impl Ezagent.Plugin
  def template_classes, do: [EzagentPluginHello.Template.HelloSession]

  # Register the builder Kind under a flavor so a cold `entity://<ws>/agent/
  # hello_<name>` (kind_type "hello_builder") can be REVIVED from its snapshot
  # after a restart. Without this, the agent-module resolver returns
  # `{:no_kind_module_for_agent, ...}` and the session's fan-out `agent.receive`
  # to the builder lands in PendingDelivery forever — @hello silently stops
  # replying. `template_class: nil` — the builder has no agent Template Class
  # (it is spawned by the session.hello session template, not an agent flavor),
  # so it must not collide with class-name resolution.
  @impl Ezagent.Plugin
  def agent_flavors do
    [
      %{
        flavor: "hello_builder",
        kind: Ezagent.Entity.HelloBuilder,
        template_class: nil
      }
    ]
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

  # Bind the builder's `:receive` page-gen hook on the `Ezagent.Entity.HelloBuilder`
  # Kind so the session's chat fan-out (`chat.send` → `chat.receive` per member)
  # reaches it. (Phase 0: the builder is spawned directly as a session member by
  # `EzagentPluginHello.App`; the agent-flavor/Template create path is a follow-up.)
  @impl Ezagent.Plugin
  def behaviors do
    # The builder's own page-gen `:receive` hook, PLUS every `Ezagent.Behavior.Identity`
    # action registered for the `HelloBuilder` Kind — so the orchestrator can
    # RECEIVE its granted within-session caps (`:grant_cap`) and dispatch resolves
    # the action. This mirrors `EzagentDomainIdentity.Application`'s registration of
    # Identity for the `User`/`Agent` Kinds, done here via the plugin contract for
    # the hello-owned Kind.
    identity_decls =
      for {behavior, actions} <- [
            {Ezagent.Behavior.Identity, Ezagent.Behavior.Identity.actions()},
            {Ezagent.Behavior.IdentityAdmin, Ezagent.Behavior.IdentityAdmin.actions()}
          ],
          action <- actions do
        {Ezagent.Entity.HelloBuilder, action, behavior}
      end

    # T2-2a — register the hello view read ActionSet's `<sw>_render` action on
    # the Session Kind. Cap-only (dispatchable? false) so this writes only the
    # `{Session, :hello_render}` cap subject; there is no dispatch route. This is
    # the cap `authorize_view/3` (T2-2b) checks for a hello page view.
    view_decls = [
      {Ezagent.Entity.Session, :hello_render, EzagentPluginHello.Behavior.HelloRender}
    ]

    [{Ezagent.Entity.HelloBuilder, :receive, Ezagent.Behavior.HelloBuilder} | identity_decls] ++
      view_decls
  end

  # The supervisor for off-process page-generation Tasks (the LLM round-trip),
  # plus an OPT-IN boot seed (off by default).
  @impl Ezagent.Plugin
  def children do
    [{Task.Supervisor, name: EzagentPluginHello.TaskSupervisor}] ++ demo_seed_children()
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
    EzagentPluginHello.TurnDriver.drive(
      session_uri,
      EzagentPluginHello.Spec.seed(),
      "Seed page — the hello builder is live."
    )
  end
end
