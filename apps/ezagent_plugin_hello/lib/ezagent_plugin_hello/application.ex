defmodule EzagentPluginHello.Application do
  @moduledoc """
  Hello plugin OTP application — the `Ezagent.Plugin` contract module.

  `hello` is an app where an AI **builder agent generates a UI page** (as a
  structured `@json-render` spec, constrained by a Zod component catalog), the
  page is **born only via `Behavior.Surface.put_version/2`** (driven by
  `Behavior.Turn`), and **anonymous external visitors view it** through the
  socialware substrate (`public_view` SessionTemplate → `CustomerFeed` →
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
  operator `PageView` registration, and the Turn/Surface generation wiring land
  in the following Phase-0 steps (0.2–0.5). Every other `Ezagent.Plugin`
  callback keeps its `use`-macro default (`[]` / `nil` / `:ok`).
  """

  use Application
  use Ezagent.Plugin

  require Logger

  @impl Application
  def start(_type, _args), do: Ezagent.Plugin.boot(__MODULE__)

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

    [{Ezagent.Entity.HelloBuilder, :receive, Ezagent.Behavior.HelloBuilder} | identity_decls]
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
  #   * /socialware/customer — the token-based CustomerFeed (what the handoff
  #     names + the integration test proves); a token is embedded so it opens
  #     with no login/membership.
  #   * /socialware/chat — the chat-feed surface (anon self-serve via membership).
  defp log_ready(session_uri) do
    s = URI.to_string(session_uri)

    Logger.info("""
    hello demo seed ready — open as an anonymous visitor (public_view, no login,
    no token — the CustomerFeed renders the approved generated page):
      /socialware/customer?session_uri=#{s}
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
