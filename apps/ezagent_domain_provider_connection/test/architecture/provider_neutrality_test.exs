defmodule Ezagent.ProviderConnection.ProviderNeutralityTest do
  use ExUnit.Case, async: true

  defmodule Detector do
    @moduledoc false

    @provider_brand ~r/\b(?:github|gitlab|bitbucket|gitea|forgejo|azure\s+devops)\b/i
    @provider_dependency ~r/\{:(?:octokit|tentacat|github|gitlab|gitea|bitbucket|req|finch|httpoison|tesla)\b/i
    @forbidden_dependency ~r/\{:(?:ezagent_domain_git|ezagent_domain_workspace|ezagent_plugin_[a-z0-9_]+)\b/
    @provider_protocol ~r/(?:api\.[a-z0-9.-]+|\/oauth\/|\/rest\/|authorization[_ -]?scope|installation[_ -]?token)/i

    def scan_source(source, path) do
      []
      |> maybe_add(source =~ @provider_brand, :provider_brand, path)
      |> maybe_add(source =~ @provider_protocol, :provider_protocol, path)
      |> maybe_add(
        String.ends_with?(path, "mix.exs") and source =~ @provider_dependency,
        :provider_dependency,
        path
      )
      |> maybe_add(
        String.ends_with?(path, "mix.exs") and source =~ @forbidden_dependency,
        :forbidden_dependency,
        path
      )
      |> Enum.reverse()
    end

    defp maybe_add(acc, true, category, path), do: [{category, path} | acc]
    defp maybe_add(acc, false, _category, _path), do: acc
  end

  @app_root Path.expand("../..", __DIR__)

  test "common production app contains no provider brand, protocol, or outward dependency" do
    paths = [Path.join(@app_root, "mix.exs") | Path.wildcard(Path.join(@app_root, "lib/**/*.ex"))]

    violations =
      Enum.flat_map(paths, fn path -> Detector.scan_source(File.read!(path), path) end)

    assert violations == []
  end

  test "common app depends inward only on core and identity" do
    dependencies = EzagentDomainProviderConnection.MixProject.project()[:deps]

    umbrella =
      for {name, options} <- dependencies,
          is_list(options) and options[:in_umbrella],
          do: name

    assert umbrella == [:ezagent_core, :ezagent_domain_identity]
  end

  test "detector catches brands, protocol paths, and provider dependencies" do
    source = """
    defmodule GithubConnection do
      @endpoint "https://api.github.com/oauth/authorize"
    end
    """

    mix_source = """
    defp deps, do: [{:tentacat, "~> 2.0"}, {:ezagent_domain_git, in_umbrella: true}]
    """

    findings = Detector.scan_source(source, "lib/provider.ex")
    assert {:provider_brand, "lib/provider.ex"} in findings
    assert {:provider_protocol, "lib/provider.ex"} in findings

    mix_findings = Detector.scan_source(mix_source, "mix.exs")
    assert {:provider_dependency, "mix.exs"} in mix_findings
    assert {:forbidden_dependency, "mix.exs"} in mix_findings
  end

  test "detector permits provider-neutral ids, hosts, and declarations" do
    source = """
    defmodule NeutralConnection do
      defstruct [:provider_id, :governed_host, :acquisition_method]
    end
    """

    assert Detector.scan_source(source, "lib/neutral.ex") == []
  end
end
