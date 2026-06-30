defmodule EzagentCli.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_cli,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      # :crypto for Ezagent.Runtime cookie generation. No HTTP deps —
      # CLI reaches the runtime via distributed Erlang RPC.
      extra_applications: [:logger, :crypto],
      mod: {EzagentCli.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ezagent_core, in_umbrella: true},
      {:ezagent_domain_agent, in_umbrella: true},
      {:ezagent_domain_identity, in_umbrella: true},
      {:ezagent_domain_workspace, in_umbrella: true},
      # Phase 3 ③ T7h — the `mix ezagent session send` verb builds a real
      # `%Ezagent.Message{}` with server-side @mention resolution via
      # `Ezagent.Session.MessageComposer` (the SAME composer the World UI chat
      # uses). That module is owned by ezagent_domain_session, so the CLI lib
      # now depends on it at compile time (previously TEST-ONLY: the invariant
      # suites already needed the Session Kind + its `session` SpawnRegistry
      # handler). No cycle — nothing in ezagent_domain_session's dep closure
      # references ezagent_cli; the CLI remains a leaf entry-point app.
      {:ezagent_domain_session, in_umbrella: true},
      {:optimus, "~> 0.5"},
      {:jason, ">= 0.0.0"}
    ]
  end
end
