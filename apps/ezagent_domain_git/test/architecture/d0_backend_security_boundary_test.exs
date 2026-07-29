defmodule Ezagent.DomainGit.D0BackendSecurityBoundaryTest do
  use ExUnit.Case, async: true

  alias Ezagent.DomainGit.D0BackendReuseGate.{
    CredentialBackend,
    ProviderAuthorizationBackend,
    RemoteTransport
  }

  @app_root Path.expand("../..", __DIR__)
  @support_root Path.join(@app_root, "test/support/d0_backend_reuse_gate")
  @git_task_access Path.join(@app_root, "lib/ezagent/behavior/git_task_access.ex")

  test "detectors reject representative forbidden source without self-literal exemptions" do
    assert scan_source("Cap" <> "." <> "issue(args)", forbidden_effect_patterns()) != []
    assert scan_source("Router" <> "." <> "dispatch(args)", forbidden_effect_patterns()) != []
    assert scan_source("File.write!(project_" <> "cwd, token)", forbidden_effect_patterns()) != []
    assert scan_source("Req" <> "." <> "post(url)", backend_transport_patterns()) != []
    assert scan_source("provider_" <> "request_plan = %{}", backend_transport_patterns()) != []
    assert scan_source("transform" <> ".(secret)", backend_closure_patterns()) != []
  end

  test "backend behaviours and Plan B public contracts remain exact" do
    assert Enum.sort(ProviderAuthorizationBackend.behaviour_info(:callbacks)) ==
             Enum.sort(
               begin_authorization: 1,
               cancel_authorization: 1,
               consume_callback: 1,
               reauthenticate: 1
             )

    assert Enum.sort(CredentialBackend.behaviour_info(:callbacks)) ==
             Enum.sort(
               consume_lease: 1,
               lease_for_operation: 1,
               replace: 1,
               revoke: 1,
               status: 1,
               store: 1
             )

    assert Ezagent.DomainGit.OperationContext.__struct__() |> Map.keys() |> Enum.sort() ==
             Enum.sort([
               :__struct__,
               :caller_uri,
               :credential_owner_uri,
               :grantee_uri,
               :idempotency_key,
               :task_access_uri
             ])

    assert Enum.sort(Ezagent.DomainGit.Adapter.behaviour_info(:callbacks)) ==
             Enum.sort(
               create_change_request: 4,
               list_checks: 3,
               list_reviews: 3,
               read_change_request: 3,
               resolve_repository: 2
             )
  end

  test "D0 executable modules remain test-only" do
    support_files = support_files!()
    assert support_files != []

    production_hits =
      Path.join(@app_root, "lib/**/*.ex")
      |> Path.wildcard()
      |> Enum.filter(&(File.read!(&1) =~ "D0BackendReuseGate"))

    assert production_hits == []

    assert Enum.all?(support_files, &String.starts_with?(&1, @support_root <> "/"))
  end

  test "D0 support contains no dispatch, capability issuance, or workspace materialization" do
    violations = scan_files(support_files!(), forbidden_effect_patterns())
    assert violations == []
  end

  test "credential backends own neither Req nor provider request plans" do
    backend_files = [
      Path.join(@support_root, "credential_backend.ex"),
      Path.join(@support_root, "in_process_fake.ex"),
      Path.join(@support_root, "remote_seal.ex"),
      Path.join(@support_root, "remote_shaped_fake.ex")
    ]

    assert Enum.all?(backend_files, &File.regular?/1)
    assert scan_files(backend_files, backend_transport_patterns()) == []
    assert scan_files(backend_files, backend_closure_patterns()) == []
  end

  test "remote serialized boundary rejects closures, pids, and references" do
    for value <- [fn -> :secret end, self(), make_ref()] do
      assert_raise ArgumentError, ~r/runtime identity cannot cross/, fn ->
        RemoteTransport.round_trip(:boundary_probe, %{value: value}, fn _, request ->
          {:ok, request}
        end)
      end
    end
  end

  test "sensitive unwrap is confined to exact private adapter probes" do
    local_probe = Path.join(@support_root, "adapter_probe.ex")
    remote_probe = Path.join(@support_root, "remote_adapter_probe.ex")
    probes = [local_probe, remote_probe]

    for file <- probes do
      source = File.read!(file)
      assert occurrence_count(source, "defp private_req(") == 1
      assert occurrence_count(source, "%SensitiveCredential{value: value}") == 1
      assert sensitive_value_pattern_lines(source) |> length() == 1
      refute source =~ "def private_req("
    end

    non_probe_files = support_files!() -- probes

    assert Enum.all?(non_probe_files, fn file ->
             source = File.read!(file)

             not String.contains?(source, "defp private_req(") and
               sensitive_value_pattern_lines(source) == []
           end)

    exact_sensitive_occurrences = %{
      Path.join(@support_root, "adapter_probe.ex") => 1,
      Path.join(@support_root, "remote_adapter_probe.ex") => 1,
      Path.join(@support_root, "in_process_fake.ex") => 1,
      Path.join(@support_root, "remote_shaped_fake.ex") => 1
    }

    actual =
      support_files!()
      |> Map.new(fn file ->
        {file, occurrence_count(File.read!(file), "%SensitiveCredential{value:")}
      end)
      |> Enum.reject(fn {_file, count} -> count == 0 end)
      |> Map.new()

    assert actual == exact_sensitive_occurrences
  end

  test "only GitTaskAccess owns adapter lookup and provider callback invocation" do
    support = Enum.map_join(support_files!(), "\n", &File.read!/1)
    refute support =~ "AdapterRegistry"
    refute support =~ "lookup_for_action_set"

    source = File.read!(@git_task_access)
    assert source =~ "AdapterRegistry.lookup_for_action_set"
    assert source =~ "invoke(adapter, action, operation_context"
  end

  defp forbidden_effect_patterns do
    [
      Regex.compile!(Regex.escape("Cap" <> "." <> "issue(")),
      Regex.compile!(Regex.escape("Router" <> "." <> "dispatch(")),
      Regex.compile!(Regex.escape("Invocation" <> "." <> "dispatch(")),
      Regex.compile!("project_" <> "cwd"),
      Regex.compile!("work" <> "tree"),
      Regex.compile!("config_" <> "dir")
    ]
  end

  defp backend_transport_patterns do
    [
      Regex.compile!(Regex.escape("Req" <> ".")),
      Regex.compile!(Regex.escape("Finch" <> ".")),
      Regex.compile!("provider_" <> "request_plan"),
      Regex.compile!("request_" <> "plan")
    ]
  end

  defp backend_closure_patterns do
    [
      Regex.compile!("seal" <> "er"),
      Regex.compile!("is_" <> "function"),
      Regex.compile!(Regex.escape("&" <> "seal/1")),
      Regex.compile!("[a-z_]\\w*\\.\\(")
    ]
  end

  defp support_files! do
    files = @support_root |> Path.join("*.ex") |> Path.wildcard() |> Enum.sort()
    assert files != []
    files
  end

  defp scan_files(files, patterns) do
    for file <- files,
        pattern <- scan_source(File.read!(file), patterns) do
      %{file: file, pattern: Regex.source(pattern)}
    end
  end

  defp scan_source(source, patterns) do
    Enum.filter(patterns, &Regex.match?(&1, source))
  end

  defp occurrence_count(source, needle) do
    source |> :binary.matches(needle) |> length()
  end

  defp sensitive_value_pattern_lines(source) do
    source
    |> Code.string_to_quoted!()
    |> pattern_roots()
    |> Enum.flat_map(fn pattern ->
      {_pattern, lines} =
        Macro.prewalk(pattern, [], fn
          {:%, meta, [{:__aliases__, _, parts}, {:%{}, _, fields}]} = node, lines ->
            if List.last(parts) == :SensitiveCredential and Keyword.has_key?(fields, :value) do
              {node, [meta[:line] | lines]}
            else
              {node, lines}
            end

          node, lines ->
            {node, lines}
        end)

      lines
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp pattern_roots(ast) do
    {_ast, roots} =
      Macro.prewalk(ast, [], fn
        {kind, _, [{:when, _, [{_name, _, args} | _guards]}, _body]} = node, roots
        when kind in [:def, :defp] and is_list(args) ->
          {node, args ++ roots}

        {kind, _, [{_name, _, args}, _body]} = node, roots
        when kind in [:def, :defp] and is_list(args) ->
          {node, args ++ roots}

        {:->, _, [patterns, _body]} = node, roots ->
          {node, patterns ++ roots}

        {operator, _, [pattern, _expression]} = node, roots when operator in [:=, :<-] ->
          {node, [pattern | roots]}

        node, roots ->
          {node, roots}
      end)

    roots
  end
end
