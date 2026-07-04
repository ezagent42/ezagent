defmodule EzagentDomainPython.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_domain_python,
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

  # Domain.Python — Tier-2 runtime for ezagent-launched Python
  # subprocesses. Per SPEC 2026-05-23-domain-python.md §1.1 the app
  # owns the Registry + DynamicSupervisor that parent
  # Ezagent.Domain.Python.Server processes. erlexec is declared in
  # both deps and extra_applications (codex round-2 HIGH-2) because
  # Server calls :exec.run/2 + :exec.stop/1 directly.
  defp package do
    [
      licenses: ["Apache-2.0"]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :erlexec],
      mod: {EzagentDomainPython.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Tier-2 rule: Domain apps depend on ezagent_core ONLY — no other
      # Domain apps, no plugin apps.
      {:ezagent_core, in_umbrella: true},
      {:jason, "~> 1.2"},
      # erlexec is the subprocess primitive — same dep
      # apps/ezagent_domain_pty/mix.exs already pulls in.
      {:erlexec, "~> 2.1"}
    ]
  end
end
