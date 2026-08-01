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

  alias Ezagent.Cap.GrantArtifact
  alias EzagentCore.Repo

  @database_prefix "ezagent_pg_compat_test_clean_"
  @database_regex ~r/\Aezagent_pg_compat_test_clean_[a-z0-9_]+\z/
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

    if Repo.config()[:database] == database do
      Mix.raise("clean-start database must differ from the ordinary test database")
    end

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
      :first_boot -> clean_start_scenario_call(:run_first_boot!)
      :cold_boot -> clean_start_scenario_call(:run_cold_boot!)
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
      [[count, 0]] when count > 0 -> assert_authority_anchors!()
      rows -> Mix.raise("clean seed produced invalid authority rows: #{inspect(rows)}")
    end
  end

  defp assert_authority_anchors! do
    sql!("SELECT uri, anchor FROM kind_cap_authorities ORDER BY uri, generation").rows
    |> Enum.each(fn [uri, encoded] ->
      clean_start_scenario_call(:validate_anchor!, [uri, encoded])
    end)
  end

  defp clean_start_scenario_call(function, args \\ []) do
    module = Module.concat([Ezagent, Test, CleanStartScenario])

    unless Code.ensure_loaded?(module) do
      Mix.raise("clean-start scenario support is unavailable outside MIX_ENV=test")
    end

    apply(module, function, args)
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
