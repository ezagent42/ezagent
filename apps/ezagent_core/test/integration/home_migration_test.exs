defmodule Ezagent.Integration.HomeMigrationTest do
  @moduledoc """
  E2E for the complete-home migration capability (home portability #120).

  Proves: seed throwaway home A (snapshot rows in the PostgreSQL test DB
  + an on-disk per-agent config_dir file) → `Ezagent.Home.Migration.backup`
  → `restore` into a DIFFERENT-path home B → read the restored Repo state →
  read back via the NORMAL read path (`Ezagent.Ecto.KindSnapshot.get/1` +
  `decode_state/1`, exactly what boot-time hydration uses) and assert:

    * the User entity's caps survived (general DB content intact);
    * the agent's persisted `config_dir_path` was REWRITTEN from home A's
      profile dir to home B's (the portability fix);
    * the on-disk per-agent config_dir file content survived the copy;
    * `respawn_template_data`'s embedded absolute path was also rewritten.

  Not `DataCase`: the migration is a filesystem+DB op around the runtime, and
  `pg_dump` must see committed rows. The test uses a non-sandbox dynamic Repo
  pointed at the configured PostgreSQL test database.
  """
  use ExUnit.Case, async: false

  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Home.Migration
  alias Ezagent.Test.SnapshotFixtures
  alias EzagentCore.Repo

  @repo_config Application.compile_env(:ezagent_core, EzagentCore.Repo)

  setup do
    base = Path.join(System.tmp_dir!(), "ezagent-home-mig-#{System.unique_integer([:positive])}")
    home_a = Path.join(base, "home-a")
    home_b = Path.join(base, "home-b")
    backup = Path.join(base, "backup.tar.gz")

    on_exit(fn ->
      stop_repo()
      File.rm_rf(base)
    end)

    {:ok, home_a: home_a, home_b: home_b, backup: backup}
  end

  test "seed home A → backup → restore into home B → caps + config_dir + rewritten paths survive",
       %{home_a: home_a, home_b: home_b, backup: backup} do
    profile = "default"
    profile_dir_a = Path.join(home_a, profile)
    profile_dir_b = Path.join(home_b, profile)

    # --- SEED home A -----------------------------------------------------
    db_a = Path.join([profile_dir_a, "db", "ezagent_core.db"])
    File.mkdir_p!(Path.dirname(db_a))
    boot_repo!(db_a)
    clean_snapshots()

    # A User entity snapshot carrying caps — proves general DB content
    # survives migration (queried via the normal read path).
    user_uri = "entity://system/user/alice"

    user_state = %{
      identity: %{
        state: %{
          caps:
            MapSet.new([
              %{kind: :agent, behavior: Ezagent.Behavior.Sandbox, action: :read}
            ])
        }
      }
    }

    {:ok, _} =
      SnapshotFixtures.upsert_kind_snapshot(
        user_uri,
        "user",
        :erlang.term_to_binary(user_state),
        0,
        "workspace://system",
        mark_ever_created: true
      )

    # An Agent's Sandbox snapshot persisting an ABSOLUTE config_dir_path
    # under home A's profile dir — the prime portability suspect.
    workspace = "team-alpha"
    agent_name = "cc_demo"
    agent_uri = "entity://#{workspace}/agent/#{agent_name}"
    config_dir_a = Path.join([profile_dir_a, "cc-agents", workspace, agent_name])

    sandbox_state = %{
      sandbox: %{
        state: %{
          config_dir_path: config_dir_a,
          template_class: EzagentPluginCc.Template.CcAgent,
          # respawn_template_data embeds the SAME absolute path a second
          # time (audit finding #2) — must also be rewritten.
          respawn_template_data: %{
            "agent_config_dir" => config_dir_a,
            "config_dir" => config_dir_a
          },
          pty_phase: :running
        }
      }
    }

    {:ok, _} =
      SnapshotFixtures.upsert_kind_snapshot(
        agent_uri,
        "agent",
        :erlang.term_to_binary(sandbox_state),
        0,
        "workspace://#{workspace}",
        mark_ever_created: true
      )

    # The real on-disk per-agent config_dir + a credentials file inside it.
    File.mkdir_p!(config_dir_a)
    creds_marker = Path.join(config_dir_a, ".credentials.json")
    File.write!(creds_marker, ~s({"agent":"cc_demo","secret":"xyz"}))

    # A credentials YAML at the profile level too.
    File.mkdir_p!(Path.join(profile_dir_a, "credentials"))
    File.write!(Path.join([profile_dir_a, "credentials", "feishu.yaml"]), "app_id: cli_seeded\n")

    stop_repo()

    # --- BACKUP (active home = A via env) --------------------------------
    {:ok, ^backup} =
      with_env("EZAGENT_HOME", home_a, fn ->
        with_env("EZAGENT_PROFILE", profile, fn -> Migration.backup(backup) end)
      end)

    assert File.regular?(backup)

    # --- RESTORE into home B (different path) ----------------------------
    boot_repo!(db_a)

    {:ok, {^profile_dir_b, rewritten}} =
      Migration.restore(backup, home_b, profile, [])

    # Two snapshot rows referenced home A; only the Sandbox row carried
    # paths → exactly 1 row rewritten.
    assert rewritten == 1

    # --- ASSERT via the NORMAL read path against home B ------------------
    db_b = Path.join([profile_dir_b, "db", "ezagent_core.db"])
    stop_repo()
    boot_repo!(db_b)

    # 1. User caps survived (general DB content intact).
    user_row = KindSnapshot.get(user_uri)
    assert user_row != nil
    assert {:ok, decoded_user} = KindSnapshot.decode_state(user_row)
    caps = decoded_user.identity.state.caps
    assert MapSet.size(caps) == 1
    assert Enum.any?(caps, &(&1.behavior == Ezagent.Behavior.Sandbox and &1.action == :read))

    # 2. Sandbox config_dir_path REWRITTEN A → B (the portability fix).
    config_dir_b = Path.join([profile_dir_b, "cc-agents", workspace, agent_name])
    agent_row = KindSnapshot.get(agent_uri)
    assert {:ok, decoded_agent} = KindSnapshot.decode_state(agent_row)
    sandbox = decoded_agent.sandbox.state

    assert sandbox.config_dir_path == config_dir_b,
           "config_dir_path must be rewritten to home B; got #{sandbox.config_dir_path}"

    refute String.contains?(sandbox.config_dir_path, home_a),
           "no home-A path may remain after restore"

    # respawn_template_data's embedded paths rewritten too.
    assert sandbox.respawn_template_data["agent_config_dir"] == config_dir_b
    assert sandbox.respawn_template_data["config_dir"] == config_dir_b

    # Non-path fields preserved exactly through decode/rewrite/encode.
    assert sandbox.template_class == EzagentPluginCc.Template.CcAgent
    assert sandbox.pty_phase == :running

    # 3. On-disk per-agent config_dir file content survived the copy.
    restored_creds = Path.join(config_dir_b, ".credentials.json")
    assert File.exists?(restored_creds)
    assert File.read!(restored_creds) == ~s({"agent":"cc_demo","secret":"xyz"})

    # Profile-level credential survived too.
    assert File.read!(Path.join([profile_dir_b, "credentials", "feishu.yaml"])) ==
             "app_id: cli_seeded\n"

    # 4. The rewritten path actually points at a real, restored directory —
    #    a "dispatch against a restored entity" (config_dir lookup) resolves.
    assert File.dir?(sandbox.config_dir_path)
  end

  test "restore refuses to clobber a non-empty target without --force", %{
    home_a: home_a,
    home_b: home_b,
    backup: backup
  } do
    profile = "default"
    db_a = Path.join([home_a, profile, "db", "ezagent_core.db"])
    File.mkdir_p!(Path.dirname(db_a))
    boot_repo!(db_a)
    clean_snapshots()

    {:ok, _} =
      SnapshotFixtures.upsert_kind_snapshot(
        "entity://system/user/bob",
        "user",
        :erlang.term_to_binary(%{identity: %{state: %{caps: MapSet.new()}}}),
        0,
        "workspace://system",
        []
      )

    stop_repo()

    {:ok, ^backup} =
      with_env("EZAGENT_HOME", home_a, fn ->
        with_env("EZAGENT_PROFILE", profile, fn -> Migration.backup(backup) end)
      end)

    # Pre-populate the target so it's non-empty.
    target_profile_dir = Path.join(home_b, profile)
    File.mkdir_p!(target_profile_dir)
    File.write!(Path.join(target_profile_dir, "occupied"), "x")

    boot_repo!(db_a)

    assert {:error, {:target_not_empty, ^target_profile_dir}} =
             Migration.restore(backup, home_b, profile, [])

    # --force overrides.
    assert {:ok, {^target_profile_dir, _}} =
             Migration.restore(backup, home_b, profile, force: true)
  end

  # Covers `rewrite_paths` round-tripping a slice that carries a module/atom
  # in `template_class` alongside a path — the prefix is rewritten and the
  # atom survives the decode → rewrite → re-encode cycle.
  #
  # NOTE on the `:safe`-decode bug found during manual e2e: the restore task
  # may run in a process where a plugin's `template_class` atom is NOT in the
  # atom table — `binary_to_term/[:safe]` would reject the whole blob and
  # silently skip the row ("rewrote 0"). That condition is
  # CROSS-PROCESS (the atom was never created in the restore BEAM) and can't
  # be reproduced inside this single test BEAM (the atom we write is already
  # in our table). The guard for it is the manual e2e in the scenario doc
  # (`mix ezagent.home.restore` → "rewrote 1"); here we lock in the in-process
  # round-trip contract.
  test "rewrite_paths round-trips a slice carrying an atom + rewrites its path",
       %{home_a: home_a} do
    profile = "default"
    profile_dir = Path.join(home_a, profile)
    db = Path.join([profile_dir, "db", "ezagent_core.db"])
    File.mkdir_p!(Path.dirname(db))
    boot_repo!(db)
    clean_snapshots()

    # A unique atom that exists in THIS process's table (so we can write it)
    # but stands in for "an atom binary_to_term/[:safe] would reject when the
    # defining module isn't loaded" — the deep_rewrite path must round-trip it.
    exotic = String.to_atom("home_mig_exotic_#{System.unique_integer([:positive])}")
    old_path = Path.join([profile_dir, "cc-agents", "ws", "cc_x"])

    blob =
      :erlang.term_to_binary(%{
        sandbox: %{state: %{config_dir_path: old_path, template_class: exotic}}
      })

    {:ok, _} =
      SnapshotFixtures.upsert_kind_snapshot(
        "entity://ws/agent/cc_x",
        "agent",
        blob,
        0,
        "workspace://ws",
        []
      )

    new_profile_dir = Path.join([home_a, "moved", profile])
    assert {:ok, 1} = Migration.rewrite_paths_for_test(db, profile_dir, new_profile_dir)

    # Read back the raw blob WITHOUT :safe (as restore does) and confirm the
    # path moved and the exotic atom survived.
    row = KindSnapshot.get("entity://ws/agent/cc_x")
    decoded = :erlang.binary_to_term(row.state_binary)
    sb = decoded.sandbox.state
    assert sb.config_dir_path == Path.join([new_profile_dir, "cc-agents", "ws", "cc_x"])
    assert sb.template_class == exotic
    stop_repo()
  end

  # --- repo lifecycle helpers ---------------------------------------------
  #
  # The full ezagent_core app already supervises `EzagentCore.Repo` against
  # the sandboxed test DB pool. We don't disturb it: instead we start a SECOND,
  # dynamically-named Repo instance using a plain pool and route
  # `KindSnapshot`/`Repo` calls to it via `put_dynamic_repo/1`. `pg_dump` sees
  # committed rows, and the migration's read/write path remains production code.

  defp boot_repo!(_db_path) do
    stop_repo()

    config =
      @repo_config
      |> Keyword.put(:pool_size, 2)
      |> Keyword.put(:name, :home_mig_repo)
      # Plain pool — `pg_dump` cannot see rows hidden inside Sandbox ownership.
      |> Keyword.delete(:pool)

    {:ok, pid} = Repo.start_link(config)
    Repo.put_dynamic_repo(:home_mig_repo)

    Process.put(:home_mig_repo_pid, pid)
    :ok
  end

  defp clean_snapshots do
    Repo.delete_all(KindSnapshot)
    :ok
  end

  defp stop_repo do
    Repo.put_dynamic_repo(Repo)

    case Process.delete(:home_mig_repo_pid) do
      nil -> :ok
      pid -> if Process.alive?(pid), do: Supervisor.stop(pid)
    end
  rescue
    _ -> :ok
  end

  defp with_env(key, value, fun) do
    prev = System.get_env(key)
    System.put_env(key, value)

    try do
      fun.()
    after
      case prev do
        nil -> System.delete_env(key)
        v -> System.put_env(key, v)
      end
    end
  end
end
