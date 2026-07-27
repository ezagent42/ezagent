defmodule EzagentDomainPty.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_domain_pty,
      version: "0.1.0",
      package: package(),
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {EzagentDomainPty.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Tier-2 rule: Domain apps depend on ezagent_core ONLY — no other
      # Domain apps, no plugin apps. PTY runtime is a Domain-tier
      # primitive that plugins (cc, future echo-with-pty, etc.) call
      # via the Ezagent.Domain.Pty facade.
      {:ezagent_actor, in_umbrella: true},
      {:ezagent_core, in_umbrella: true},
      # erlexec is the PTY backend — used by Ezagent.Domain.Pty.Server
      # to allocate a real tty for child processes (claude TUI requires
      # this; native Port.open(:spawn) doesn't allocate a pty).
      {:erlexec, "~> 2.1"}
    ]
  end
end
