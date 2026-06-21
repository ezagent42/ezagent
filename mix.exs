defmodule EzagentCore.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      name: "Ezagent",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      docs: docs(),
      releases: releases(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # OTP release for prod docker (mix release). An umbrella release only starts
  # the apps listed here (plus their deps) — the plugins are NOT in ezagent_web's
  # dep tree (they're started as sibling apps), so EVERY runnable app must be
  # listed explicitly or it silently won't boot in the release.
  # `ezagent_cli` is task-only → :load (available, not started).
  defp releases do
    [
      ezagent: [
        applications: [
          ezagent_core: :permanent,
          ezagent_domain_identity: :permanent,
          ezagent_domain_workspace: :permanent,
          ezagent_domain_session: :permanent,
          ezagent_domain_socialware: :permanent,
          ezagent_domain_agent_bridge: :permanent,
          ezagent_domain_agent: :permanent,
          ezagent_domain_external_mirror: :permanent,
          ezagent_domain_pty: :permanent,
          ezagent_domain_python: :permanent,
          ezagent_domain_ui: :permanent,
          ezagent_plugin_cc: :permanent,
          ezagent_plugin_codex: :permanent,
          ezagent_plugin_curl_agent: :permanent,
          ezagent_plugin_advisor: :permanent,
          ezagent_plugin_echo: :permanent,
          ezagent_plugin_np: :permanent,
          ezagent_plugin_feishu: :permanent,
          ezagent_plugin_liveview: :permanent,
          ezagent_plugin_world: :permanent,
          ezagent_web: :permanent,
          ezagent_cli: :load
        ],
        include_executables_for: [:unix]
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Dependencies can be Hex packages:
  #
  #   {:mydep, "~> 0.3.0"}
  #
  # Or git/path repositories:
  #
  #   {:mydep, git: "https://github.com/elixir-lang/mydep.git", tag: "0.1.0"}
  #
  # Type "mix help deps" for more examples and options.
  #
  # Dependencies listed here are available only for this project
  # and cannot be accessed from applications inside the apps/ folder.
  defp deps do
    [
      # Required to run "mix format" on ~H/.heex files from the umbrella root
      {:phoenix_live_view, ">= 0.0.0"},
      # Generates browsable HTML API docs from the apps' @moduledocs.
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  # Configures `mix docs` (ExDoc). Run from the umbrella root to aggregate
  # every child app's modules into a single browsable doc/ tree.
  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "ARCHITECTURE.md",
        "GLOSSARY.md",
        "IMPLEMENTATION_ROADMAP.md",
        "docs/notes/README.md": [title: "Forensic Notes Index"]
      ],
      groups_for_extras: [
        Project: ["README.md", "ARCHITECTURE.md", "GLOSSARY.md", "IMPLEMENTATION_ROADMAP.md"],
        Notes: ["docs/notes/README.md"]
      ],
      source_url: "https://github.com/ezagent42/esr-ng"
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  #
  # Aliases listed here are available only for this project
  # and cannot be accessed from applications inside the apps/ folder.
  defp aliases do
    [
      # run `mix setup` in all child apps
      setup: ["cmd mix setup"],
      # FF-3 (cleanup-4) — the compiler dead-code gate. `--warnings-as-errors`
      # is the ONLY reliable detector of unused private functions + unreachable
      # / mis-grouped clauses (the cleanup audit proved grep-based dead-code
      # detection is ~100% false-positive for this class). `--force` makes the
      # gate sound: an incremental compile silently skips unchanged modules, so
      # a warning re-introduced in an otherwise-untouched file would slip past.
      # Mirrored by the architecture test
      # `compiler_dead_code_gate_test.exs`. Keep these flags in sync.
      precommit: [
        "compile --warnings-as-errors --force",
        "deps.unlock --unused",
        "format",
        "test"
      ]
    ]
  end
end
