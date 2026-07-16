defmodule EzagentCore.Architecture.GitAdapterBoundaryScanner do
  @moduledoc false

  @domain_root "apps/ezagent_domain_git"
  @action_set_path "apps/ezagent_domain_git/lib/ezagent/behavior/git_task_access.ex"
  @callbacks ~w(resolve_repository create_change_request read_change_request list_checks list_reviews)
  @provider_names ~r/(?:GitHub|Github|GitLab|Gitlab|Bitbucket|Gitea|Forgejo)/
  @provider_deps ~r/\{:(?:req|httpoison|tesla|tentacat|github|gitlab|goth|finch)\b/i
  @forbidden_field ~r/^(?:token|tokens|secret|secrets|credential|credentials|req|request_client|client|local_path|checkout_path|cap|caps)$/i
  @forbidden_callback ~r/\b(?:token|tokens|secret|secrets|credential|credentials|Req(?:\.[A-Z]\w*)?|client|local_path|checkout_path|Cap(?:ability)?)\b/

  def empty_findings do
    %{
      adapter_effects: [],
      provider_modules: [],
      provider_dependencies: [],
      forbidden_struct_fields: [],
      forbidden_callback_terms: []
    }
  end

  def scan_repository(repo_root) do
    sources =
      Path.wildcard(Path.join(repo_root, @domain_root <> "/lib/**/*.ex"))
      |> Enum.map(fn path ->
        relative = Path.relative_to(path, repo_root)
        {relative, File.read!(path)}
      end)

    findings =
      Enum.reduce(sources, empty_findings(), fn {path, source}, acc ->
        merge(acc, scan_source(path, source))
      end)

    mix_path = Path.join(repo_root, @domain_root <> "/mix.exs")

    if File.read!(mix_path) =~ @provider_deps do
      %{findings | provider_dependencies: [Path.relative_to(mix_path, repo_root)]}
    else
      findings
    end
  end

  def scan_source(path, source) do
    %{
      adapter_effects: adapter_effects(path, source),
      provider_modules: provider_modules(path, source),
      provider_dependencies: provider_dependencies(path, source),
      forbidden_struct_fields: forbidden_struct_fields(path, source),
      forbidden_callback_terms: forbidden_callback_terms(path, source)
    }
  end

  defp adapter_effects(@action_set_path, _source), do: []

  defp adapter_effects(path, source) do
    callback = Enum.join(@callbacks, "|")

    matcher =
      ~r/(?:AdapterRegistry\.lookup_for_action_set\s*\(|\b\w+\.(?:#{callback})\s*\(|\bapply\s*\(\s*(?:adapter|module)\b)/

    matching_lines(path, source, matcher)
  end

  defp provider_modules(path, source) do
    if String.starts_with?(path, @domain_root <> "/lib/") and
         Regex.match?(~r/\b(?:#{@provider_names.source})[A-Za-z0-9_.]*/, source) do
      [path]
    else
      []
    end
  end

  defp provider_dependencies(path, source) do
    if String.ends_with?(path, "/mix.exs") and source =~ @provider_deps, do: [path], else: []
  end

  defp forbidden_struct_fields(path, source) do
    fields =
      Regex.scan(~r/@fields\s+\[([^\]]*)\]|defstruct\s+\[([^\]]*)\]/s, source)
      |> Enum.flat_map(fn captures -> captures |> tl() |> Enum.reject(&(&1 == "")) end)
      |> Enum.flat_map(&Regex.scan(~r/:([a-zA-Z_][a-zA-Z0-9_]*)/, &1, capture: :all_but_first))
      |> List.flatten()
      |> Enum.filter(&Regex.match?(@forbidden_field, &1))

    Enum.map(fields, &{path, &1})
  end

  defp forbidden_callback_terms(path, source) do
    Regex.scan(~r/@callback\b.*?(?=\n\s*@callback\b|\nend\b)/s, source, return: :index)
    |> Enum.flat_map(fn [{offset, length}] ->
      callback = binary_part(source, offset, length)

      if callback =~ @forbidden_callback do
        line_no = source |> binary_part(0, offset) |> String.split("\n") |> length()
        [{path, line_no, callback |> String.split("\n") |> hd() |> String.trim()}]
      else
        []
      end
    end)
  end

  defp matching_lines(path, source, matcher) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _line_no} -> line =~ matcher end)
    |> Enum.map(fn {line, line_no} -> {path, line_no, String.trim(line)} end)
  end

  defp merge(left, right) do
    Map.new(left, fn {key, values} -> {key, values ++ Map.fetch!(right, key)} end)
  end
end

defmodule EzagentCore.Architecture.GitAdapterBoundaryTest do
  use ExUnit.Case, async: true

  alias EzagentCore.Architecture.GitAdapterBoundaryScanner, as: Scanner

  @repo_root Path.expand("../../../..", __DIR__)

  test "adapter selection and callback execution stay in GitTaskAccess" do
    assert Scanner.scan_repository(@repo_root).adapter_effects == []
  end

  test "domain app contains no provider implementation or provider dependency" do
    findings = Scanner.scan_repository(@repo_root)
    assert findings.provider_modules == []
    assert findings.provider_dependencies == []
  end

  test "domain structs and adapter callbacks carry no effectful authority" do
    findings = Scanner.scan_repository(@repo_root)
    assert findings.forbidden_struct_fields == []
    assert findings.forbidden_callback_terms == []
  end

  describe "controlled detector fixtures" do
    test "positive fixtures plant every forbidden boundary crossing" do
      source = """
      defmodule Ezagent.DomainGit.GitHubClient do
        @fields [:token, :local_path]
        defstruct @fields
        @callback fetch(
                    Req.Request.t(),
                    client :: term()
                  ) :: term()
        def bypass(adapter), do: adapter.resolve_repository(:context, :repository)
        def lookup, do: Ezagent.DomainGit.AdapterRegistry.lookup_for_action_set("github")
      end
      """

      findings = Scanner.scan_source("apps/ezagent_domain_git/lib/github_client.ex", source)

      assert findings.adapter_effects != []
      assert findings.provider_modules != []
      assert findings.forbidden_struct_fields != []
      assert findings.forbidden_callback_terms != []
    end

    test "negative fixtures retain declaration validation and neutral values" do
      source = """
      defmodule Ezagent.DomainGit.AdapterRegistry do
        alias Ezagent.DomainGit.Adapter
        def validate(module) do
          Adapter.behaviour_info(:callbacks)
          |> Enum.all?(fn {name, arity} -> function_exported?(module, name, arity) end)
        end
      end

      defmodule Ezagent.DomainGit.RepositoryRef do
        defstruct [:repository_uri, :provider_adapter, :owner, :name]
      end
      """

      assert Scanner.scan_source(
               "apps/ezagent_domain_git/lib/ezagent/domain_git/adapter_registry.ex",
               source
             ) == Scanner.empty_findings()
    end
  end
end
