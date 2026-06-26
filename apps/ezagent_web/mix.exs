defmodule EzagentWeb.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_web,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {EzagentWeb.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.0"},
      {:phoenix_ecto, "~> 4.5"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 0.26"},
      {:swoosh, "~> 1.17"},
      {:gen_smtp, "~> 1.2"},
      {:ezagent_core, in_umbrella: true},
      {:ezagent_domain_identity, in_umbrella: true},
      {:ezagent_domain_workspace, in_umbrella: true},
      # PR-J — HomeLive's first-login wizard calls
      # `EzagentDomainInstanceMessage.SessionCreator.create_session/2` to spawn session://default/default/main on
      # demand (replacing the static boot child). domain_ui supplies
      # the shared atom palette (button / card / page_header) for the
      # wizard layout.
      {:ezagent_domain_session, in_umbrella: true},
      # #51 §4.1 — the socialware chat-feed controller calls
      # `Ezagent.Socialware.{AnonUser, AnonBinding, PublicView, ChatFeedAuth}`
      # directly (anon-access mint/join/cookie). Declared as a prod dep so the
      # hard refs are backed by a declared umbrella dependency (the #57
      # `undeclared_umbrella_dep_test` gate); previously `ChatFeedAuth` was only
      # transitively reachable through another plugin/advisor path (a latent
      # layering hazard now closed).
      {:ezagent_domain_socialware, in_umbrella: true},
      {:ezagent_domain_agent_bridge, in_umbrella: true},
      {:ezagent_domain_ui, in_umbrella: true},
      # World PR-0: host-scoped React/shadcn app mounted by LiveView.
      # Router references EzagentPluginWorld.WorldLive by module atom.
      {:ezagent_plugin_world, in_umbrella: true},
      {:ezagent_plugin_hello, in_umbrella: true},
      {:ezagent_plugin_protocol_api, in_umbrella: true},
      # Phase 5 PR 6: Feishu webhook route forwards to
      # EzagentPluginFeishu.WebhookPlug — needed at compile time so the
      # router macro resolves the module atom.
      {:ezagent_plugin_feishu, in_umbrella: true},
      # Phase 6 PR 4: CC channel v2 WS Socket is mounted in
      # EzagentWeb.Endpoint. The plugin compiles first so the Socket
      # module is loadable when the endpoint boots.
      {:ezagent_plugin_cc, in_umbrella: true},
      # AgentBridge PR-G: Codex agent plugin. Application boot
      # registers the "codex" shared Agent flavor and bridge adapter.
      {:ezagent_plugin_codex, in_umbrella: true},
      # PR #126: curl-agent plugin (remote LLM completion proxy with
      # per-user API keys). Application boot registers the Template
      # Class so it shows up in the workspace add-template form.
      {:ezagent_plugin_curl_agent, in_umbrella: true},
      # py-agent — the general operator-script python flavor. Web boot must
      # start it so the "py" flavor registers in AgentFlavorRegistry +
      # `py.agent` in TemplateRegistry (locked by all_plugin_apps_wired_to_web).
      {:ezagent_plugin_py, in_umbrella: true},
      # Role-foundation RF-8 — native plugin (the generic no-engine host for
      # role agents). Web boot must start it so the "native" flavor + its
      # CapMint cap-policy register in AgentFlavorRegistry.
      {:ezagent_plugin_native, in_umbrella: true},
      # task #88 — ezagent.chat email capability (CLI-only). World/web reach
      # Ezagent.Email via runtime-apply; declared here so its OTP app boots.
      {:ezagent_plugin_email, in_umbrella: true},
      # kanban-as-role — declared so the kanban plugin's OTP app boots (its
      # roles/0 registers the kanban-manager recipe + its Behavior/support
      # modules load). The world UI wiring (read-model list-by-role + the
      # entity://agent dispatch target) lands in the K4 follow-up.
      {:ezagent_plugin_kanban, in_umbrella: true},
      {:jason, "~> 1.2"},
      {:bandit, "~> 1.5"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": [
        "cmd --cd assets npm install",
        "cmd --cd ../ezagent_plugin_world/assets npm install",
        "tailwind.install --if-missing",
        "esbuild.install --if-missing"
      ],
      "assets.build": [
        "tailwind ezagent_web",
        "tailwind ezagent_web_customer",
        "cmd --cd ../ezagent_plugin_world/assets npm run build",
        "esbuild ezagent_web"
      ],
      "assets.deploy": [
        "tailwind ezagent_web --minify",
        "tailwind ezagent_web_customer --minify",
        "cmd --cd ../ezagent_plugin_world/assets npm run build",
        "esbuild ezagent_web --minify",
        "phx.digest"
      ]
    ]
  end
end
