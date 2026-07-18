defmodule Ezagent.DomainGit.GitTaskAccessPrincipalBoundaryTest do
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @git_task_access Path.join(
                     @root,
                     "apps/ezagent_domain_git/lib/ezagent/entity/git_task_access.ex"
                   )
  @authority_patterns [
    ~r/\bcaller(?:_uri)?\s*:/,
    ~r/\bgranted_by\s*:/,
    ~r/\bmember(?:_uri)?\s*:/,
    ~r/\b(?:entity_)?tokens?\b/,
    ~r/SystemPrincipal/
  ]

  test "GitTaskAccess is a constrained live entity, never a principal authority" do
    authority_sites =
      @root
      |> Path.join("**/*.{ex,exs}")
      |> Path.wildcard()
      |> Enum.reject(&(&1 == __ENV__.file))
      |> Enum.flat_map(&authority_sites/1)

    assert authority_sites != [], "authority scan must cover concrete constructor sites"

    violations =
      Enum.filter(authority_sites, fn {_path, _line, source} ->
        String.contains?(source, ["GitTaskAccess", "git_task_access", "task_access_uri"])
      end)

    assert violations == [],
           "GitTaskAccess must not be caller, grantor, member, token identity, or SystemPrincipal: #{inspect(violations)}"

    source = File.read!(@git_task_access)
    assert source =~ "pattern: :entity"
    refute source =~ "pattern: :resource"
  end

  defp authority_sites(path) do
    path
    |> File.stream!()
    |> Stream.with_index(1)
    |> Enum.flat_map(fn {source, line} ->
      if Enum.any?(@authority_patterns, &Regex.match?(&1, source)),
        do: [{path, line, String.trim(source)}],
        else: []
    end)
  end
end
