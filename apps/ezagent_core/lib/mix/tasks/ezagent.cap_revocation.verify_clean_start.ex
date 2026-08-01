defmodule Mix.Tasks.Ezagent.CapRevocation.VerifyCleanStart do
  @shortdoc "Verify the grant protocol from an empty disposable database"

  @moduledoc """
  Creates one uniquely named disposable test database, migrates it from zero,
  seeds the identity root, boots the application twice in separate OS processes,
  validates the clean grant schema/artifacts, and drops the exact database in an
  `after` block.

  The task runs only under `MIX_ENV=test`. Database identifiers must match the
  private `ezagent_pg_compat_test_clean_*` namespace before any SQL interpolation.
  """

  use Mix.Task

  @requirements ["compile"]

  alias Ezagent.Cap.{Authority, Grant, GrantArtifact, RevocationLedger}
  alias Ezagent.Capability
  alias EzagentCore.Repo

  @database_prefix "ezagent_pg_compat_test_clean_"
  @database_regex ~r/\Aezagent_pg_compat_test_clean_[a-z0-9_]+\z/
  @proof_holder "entity://clean-start/agent/revocation-proof"
  @proof_target "session://clean-start/default/revocation-proof"

  @boot_apps [
    :ezagent_core,
    :ezagent_domain_identity,
    :ezagent_domain_workspace,
    :ezagent_domain_session,
    :ezagent_domain_socialware,
    :ezagent_domain_agent_bridge,
    :ezagent_domain_agent,
    :ezagent_domain_external_mirror,
    :ezagent_domain_pty,
    :ezagent_domain_python,
    :ezagent_domain_ui,
    :ezagent_plugin_cc,
    :ezagent_plugin_codex,
    :ezagent_plugin_curl_agent,
    :ezagent_plugin_email,
    :ezagent_plugin_py,
    :ezagent_plugin_feishu,
    :ezagent_plugin_github,
    :ezagent_plugin_world,
    :ezagent_plugin_hello,
    :ezagent_plugin_protocol_api,
    :ezagent_plugin_kb,
    :ezagent_web
  ]

  @impl Mix.Task
  def run(["__phase__", phase]) do
    run_child_phase!(String.to_existing_atom(phase))
  end

  def run([]) do
    unless Mix.env() == :test do
      Mix.raise("clean-start verification must run with MIX_ENV=test")
    end

    execute()
  end

  def run(_args), do: Mix.raise("usage: mix ezagent.cap_revocation.verify_clean_start")

  @doc false
  @spec valid_database_name?(term()) :: boolean()
  def valid_database_name?(database) when is_binary(database),
    do: Regex.match?(@database_regex, database)

  def valid_database_name?(_database), do: false

  @doc false
  @spec child_env(String.t(), String.t()) :: [{String.t(), String.t()}]
  def child_env(database, partition) do
    assert_database_name!(database)

    [
      {"MIX_ENV", "test"},
      {"MIX_TEST_PARTITION", partition},
      {"EZAGENT_TEST_DATABASE", database}
    ]
  end

  @doc false
  @spec phase_specs() :: [{atom(), [String.t()]}]
  def phase_specs do
    for phase <- [:migrate, :seed, :first_boot, :cold_boot] do
      {phase, ["ezagent.cap_revocation.verify_clean_start", "__phase__", Atom.to_string(phase)]}
    end
  end

  @doc false
  @spec execute(keyword()) :: :ok
  def execute(opts \\ []) do
    suffix = unique_suffix()
    database = Keyword.get(opts, :database, @database_prefix <> suffix)
    partition = Keyword.get(opts, :partition, "clean_" <> suffix)
    create_database = Keyword.get(opts, :create_database, &create_database!/1)
    drop_database = Keyword.get(opts, :drop_database, &drop_database!/1)
    run_child = Keyword.get(opts, :run_child, &system_child/3)

    assert_database_name!(database)
    env = child_env(database, partition)

    create_database.(database)

    try do
      Enum.each(phase_specs(), fn {phase, args} ->
        Mix.shell().info("clean-start phase: #{phase}")

        case run_child.(phase, args, env) do
          {output, 0} ->
            if output != "", do: Mix.shell().info(output)

          {output, status} ->
            Mix.raise("clean-start #{phase} failed with exit #{status}:\n#{output}")
        end
      end)

      Mix.shell().info("clean-start verification passed")
      :ok
    after
      drop_database.(database)
    end
  end

  defp run_child_phase!(phase) do
    assert_child_database!()
    run_phase!(phase)
  end

  defp run_phase!(:migrate) do
    Mix.Task.run("ecto.migrate", ["--quiet"])
  end

  defp run_phase!(:seed) do
    ensure_started!(:ezagent_domain_identity)
    assert_clean_state!()
  end

  defp run_phase!(phase) when phase in [:first_boot, :cold_boot] do
    Enum.each(@boot_apps, &ensure_started!/1)
    assert_clean_state!()

    case phase do
      :first_boot -> run_first_boot_scenario!()
      :cold_boot -> run_cold_boot_scenario!()
    end
  end

  defp run_phase!(phase), do: Mix.raise("unknown clean-start phase: #{inspect(phase)}")

  defp assert_child_database! do
    expected = System.fetch_env!("EZAGENT_TEST_DATABASE")
    configured = Repo.config()[:database]

    unless Mix.env() == :test and configured == expected do
      Mix.raise(
        "clean-start child database mismatch: expected=#{inspect(expected)} " <>
          "configured=#{inspect(configured)} env=#{inspect(Mix.env())}"
      )
    end
  end

  defp assert_clean_state! do
    refute_schema_object!("identity_cutover", :table)
    refute_schema_object!("users.caps_json", :column)
    assert_grant_id_column!("cap_revocations")
    assert_grant_id_column!("cap_delivery_outbox")
    assert_identity_store!()
    assert_authority_rows!()
    :ok
  end

  defp refute_schema_object!("identity_cutover", :table) do
    result =
      sql!(
        "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'identity_cutover'"
      )

    unless scalar(result) == 0, do: Mix.raise("identity_cutover compatibility table exists")
  end

  defp refute_schema_object!("users.caps_json", :column) do
    result =
      sql!(
        "SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'users' AND column_name = 'caps_json'"
      )

    unless scalar(result) == 0, do: Mix.raise("users.caps_json compatibility column exists")
  end

  defp assert_grant_id_column!(table) do
    result =
      sql!(
        "SELECT data_type, is_nullable FROM information_schema.columns " <>
          "WHERE table_schema = 'public' AND table_name = $1 AND column_name = 'grant_id'",
        [table]
      )

    unless result.rows == [["uuid", "NO"]] do
      Mix.raise("#{table}.grant_id must be a non-null UUID, got #{inspect(result.rows)}")
    end
  end

  defp assert_identity_store! do
    result = sql!("SELECT identity_status, caps_json FROM identity_caps ORDER BY uri")

    if result.rows == [], do: Mix.raise("clean seed did not create an identity Store row")

    Enum.each(result.rows, fn [status, caps_json] ->
      unless status in ["staged", "active", "revoked_unprovisioned", "tombstoned"] do
        Mix.raise("invalid identity_status #{inspect(status)}")
      end

      with {:ok, encoded} when is_list(encoded) <- Jason.decode(caps_json),
           true <- Enum.all?(encoded, &match?({:ok, _artifact}, GrantArtifact.from_map(&1))) do
        :ok
      else
        _ -> Mix.raise("identity Store contains a malformed grant artifact set")
      end
    end)
  end

  defp assert_authority_rows! do
    result =
      sql!(
        "SELECT count(*), count(*) FILTER (WHERE generation < 1 OR sealed IS NOT TRUE OR " <>
          "key_id IS NULL OR public_key IS NULL OR private_key IS NULL OR anchor IS NULL) " <>
          "FROM kind_cap_authorities"
      )

    case result.rows do
      [[count, 0]] when count > 0 -> :ok
      rows -> Mix.raise("clean seed produced invalid authority rows: #{inspect(rows)}")
    end
  end

  defp run_first_boot_scenario! do
    holder = proof_holder()
    self_license = issue_self_license!(holder)
    first = issue_proof_artifact!()

    expect!(:ok, identity_store_call(:initialize, [holder, [self_license]]))
    expect!(:ok, identity_store_call(:persist, [holder, [self_license, first]]))
    assert_authorized!(holder, first)

    case identity_store_call(:revoke_cap, [holder, first]) do
      {:ok, %Capability{grant_id: grant_id}} when grant_id == first.grant_id -> :ok
      other -> Mix.raise("clean-start exact revoke failed: #{inspect(other)}")
    end

    assert_denied!(holder, first)

    second = issue_proof_artifact!()

    if second.grant_id == first.grant_id do
      Mix.raise("clean-start re-grant reused grant_id #{first.grant_id}")
    end

    expect!(:ok, identity_store_call(:persist, [holder, [self_license, second]]))
    assert_authorized!(holder, second)
    Mix.shell().info("clean-start first boot grant/revoke/re-grant scenario passed")
  end

  defp run_cold_boot_scenario! do
    holder = proof_holder()

    caps =
      case identity_store_call(:fetch_durable_caps, [holder]) do
        {:ok, artifacts} -> artifacts
        other -> Mix.raise("clean-start cold boot Store read failed: #{inspect(other)}")
      end

    current =
      Enum.find(caps, fn cap ->
        cap.action == :send and same_instance?(cap.instance, proof_target())
      end) || Mix.raise("clean-start cold boot lost the re-granted artifact")

    old_grant_id = revoked_proof_grant_id!()

    if old_grant_id == current.grant_id do
      Mix.raise("clean-start cold boot found the current grant in the revocation ledger")
    end

    old = issue_proof_artifact!(old_grant_id)
    assert_denied!(holder, old)
    assert_authorized!(holder, current)

    expect!(
      {:error, {:revoked_capability_grants, [old_grant_id]}},
      RevocationLedger.ensure_unrevoked(proof_workspace(), [old])
    )

    expect!(:ok, RevocationLedger.ensure_unrevoked(proof_workspace(), [current]))
    Mix.shell().info("clean-start cold boot revocation persistence scenario passed")
  end

  defp issue_self_license!(holder) do
    {:ok, authority} = Authority.open(holder, :agent, :created)

    request =
      Capability.cap(
        :agent,
        Ezagent.ActionSet.Identity,
        :self_license,
        holder,
        proof_workspace()
      )

    intent = Grant.freeze(holder, holder, holder, request)

    case Grant.issue_self_license(authority, intent) do
      {:ok, %Capability{} = artifact} -> artifact
      other -> Mix.raise("clean-start self-license issuance failed: #{inspect(other)}")
    end
  end

  defp issue_proof_artifact!(grant_id \\ nil) do
    holder = proof_holder()
    target = proof_target()
    {:ok, authority} = Authority.open(target, :session, :created)

    request =
      Capability.cap(
        :session,
        Ezagent.ActionSet.Session,
        :send,
        target,
        proof_workspace()
      )

    artifact = Grant.issue(authority, Grant.freeze(target, holder, holder, request))

    case {artifact, grant_id} do
      {%Capability{} = issued, nil} ->
        issued

      {%Capability{} = issued, id} when is_binary(id) ->
        Authority.sign(authority, %{issued | grant_id: id})

      {other, _grant_id} ->
        Mix.raise("clean-start proof grant issuance failed: #{inspect(other)}")
    end
  end

  defp assert_authorized!(holder, artifact) do
    case Ezagent.Cap.authorize(holder, [artifact], proof_needed()) do
      {:ok, %Capability{grant_id: grant_id}} when grant_id == artifact.grant_id -> :ok
      other -> Mix.raise("clean-start authorization failed: #{inspect(other)}")
    end
  end

  defp assert_denied!(holder, artifact) do
    case Ezagent.Cap.authorize(holder, [artifact], proof_needed()) do
      {:error, :no_matching_cap} -> :ok
      other -> Mix.raise("clean-start revoked artifact was not denied: #{inspect(other)}")
    end
  end

  defp revoked_proof_grant_id! do
    result =
      sql!(
        "SELECT grant_id::text FROM cap_revocations " <>
          "WHERE holder_uri = $1 AND target_uri = $2 ORDER BY revoked_at",
        [Ezagent.URI.stable_key(proof_holder()), Ezagent.URI.stable_key(proof_target())]
      )

    case result.rows do
      [[grant_id]] -> grant_id
      rows -> Mix.raise("clean-start expected one revoked proof grant, got #{inspect(rows)}")
    end
  end

  defp proof_needed do
    %{
      kind: :session,
      behavior: Ezagent.ActionSet.Session,
      action: :send,
      instance: proof_target(),
      workspace_uri: proof_workspace()
    }
  end

  defp proof_holder, do: Ezagent.URI.new!(@proof_holder)
  defp proof_target, do: Ezagent.URI.new!(@proof_target)
  defp proof_workspace, do: Ezagent.URI.new!("workspace://clean-start")
  defp identity_store_call(function, args), do: apply(identity_store(), function, args)
  defp identity_store, do: Module.concat([Ezagent, IdentityCaps, Store])

  defp same_instance?(%URI{} = left, %URI{} = right),
    do: Ezagent.URI.stable_key(Ezagent.URI.instance(left)) == Ezagent.URI.stable_key(right)

  defp same_instance?(_left, _right), do: false

  defp expect!(expected, expected), do: :ok

  defp expect!(expected, actual) do
    Mix.raise("clean-start expected #{inspect(expected)}, got #{inspect(actual)}")
  end

  defp sql!(statement, params \\ []), do: Ecto.Adapters.SQL.query!(Repo, statement, params)
  defp scalar(%{rows: [[value]]}), do: value

  defp ensure_started!(app) do
    case Application.ensure_all_started(app) do
      {:ok, _started} -> :ok
      {:error, reason} -> Mix.raise("failed to start #{app}: #{inspect(reason)}")
    end
  end

  defp system_child(_phase, args, env) do
    System.cmd(System.find_executable("mix") || "mix", args,
      cd: repo_root(),
      env: env,
      stderr_to_stdout: true
    )
  end

  defp create_database!(database) do
    with_admin_connection(fn connection ->
      Postgrex.query!(connection, "CREATE DATABASE #{quoted_database!(database)}", [])
    end)
  end

  defp drop_database!(database) do
    with_admin_connection(fn connection ->
      Postgrex.query!(
        connection,
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity " <>
          "WHERE datname = $1 AND pid <> pg_backend_pid()",
        [database]
      )

      Postgrex.query!(connection, "DROP DATABASE IF EXISTS #{quoted_database!(database)}", [])
    end)
  end

  defp with_admin_connection(fun) do
    {:ok, _started} = Application.ensure_all_started(:postgrex)
    repo_config = Application.fetch_env!(:ezagent_core, Repo)

    opts =
      repo_config
      |> Keyword.take([:hostname, :port, :username, :password, :ssl, :socket_options])
      |> Keyword.put(:database, "postgres")

    {:ok, connection} = Postgrex.start_link(opts)

    try do
      fun.(connection)
    after
      GenServer.stop(connection)
    end
  end

  defp quoted_database!(database) do
    assert_database_name!(database)
    ~s("#{database}")
  end

  defp assert_database_name!(database) do
    unless valid_database_name?(database) do
      Mix.raise("unsafe clean-start database name: #{inspect(database)}")
    end
  end

  defp unique_suffix do
    integer = System.unique_integer([:positive, :monotonic])
    random = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    "#{integer}_#{random}"
  end

  defp repo_root do
    {root, 0} = System.cmd("git", ["rev-parse", "--show-toplevel"])
    String.trim(root)
  end
end
