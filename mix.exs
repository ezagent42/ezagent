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
      listeners: [Phoenix.CodeReloader]
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
      precommit: ["compile --warning-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
