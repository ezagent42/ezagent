defmodule EzagentCore.MigrationGateTest do
  @moduledoc """
  Env-var matrix for `EzagentCore.MigrationGate.skip?/0` — the boot
  gate wired into `{Ecto.Migrator, skip: ...}` (application.ex child ④).

  `async: false` because each test mutates process-global env vars; the
  setup snapshots + restores `RELEASE_NAME`, `MIX_ENV`, and
  `EZAGENT_SKIP_MIGRATIONS` so the suite is self-contained even when run
  in isolation under `MIX_ENV=test`.
  """

  use ExUnit.Case, async: false

  alias EzagentCore.MigrationGate

  @vars ["RELEASE_NAME", "MIX_ENV", "EZAGENT_SKIP_MIGRATIONS"]

  setup do
    saved = Map.new(@vars, &{&1, System.get_env(&1)})
    Enum.each(@vars, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    :ok
  end

  describe "skip?/0 — default skip semantics" do
    test "no env vars set (dev/test default) -> skip" do
      assert MigrationGate.skip?()
    end

    test "MIX_ENV=dev -> skip" do
      System.put_env("MIX_ENV", "dev")
      assert MigrationGate.skip?()
    end

    test "MIX_ENV=test -> skip" do
      System.put_env("MIX_ENV", "test")
      assert MigrationGate.skip?()
    end
  end

  describe "skip?/0 — run conditions" do
    test "RELEASE_NAME present (mix release) -> run (skip=false)" do
      System.put_env("RELEASE_NAME", "ezagent")
      refute MigrationGate.skip?()
    end

    test "MIX_ENV=prod (mix phx.server in prod) -> run (skip=false)" do
      System.put_env("MIX_ENV", "prod")
      refute MigrationGate.skip?()
    end

    test "both RELEASE_NAME and MIX_ENV=prod -> run (skip=false)" do
      System.put_env("RELEASE_NAME", "ezagent")
      System.put_env("MIX_ENV", "prod")
      refute MigrationGate.skip?()
    end

    test "empty RELEASE_NAME is treated as unset" do
      System.put_env("RELEASE_NAME", "")
      assert MigrationGate.skip?()
    end
  end

  describe "skip?/0 — explicit override (escape hatch)" do
    test "EZAGENT_SKIP_MIGRATIONS=1 overrides RELEASE_NAME" do
      System.put_env("RELEASE_NAME", "ezagent")
      System.put_env("EZAGENT_SKIP_MIGRATIONS", "1")
      assert MigrationGate.skip?()
    end

    test "EZAGENT_SKIP_MIGRATIONS=1 overrides MIX_ENV=prod" do
      System.put_env("MIX_ENV", "prod")
      System.put_env("EZAGENT_SKIP_MIGRATIONS", "1")
      assert MigrationGate.skip?()
    end

    test "EZAGENT_SKIP_MIGRATIONS=true (case-insensitive) also skips" do
      System.put_env("MIX_ENV", "prod")
      System.put_env("EZAGENT_SKIP_MIGRATIONS", "TRUE")
      assert MigrationGate.skip?()
    end

    test "EZAGENT_SKIP_MIGRATIONS=yes also skips" do
      System.put_env("MIX_ENV", "prod")
      System.put_env("EZAGENT_SKIP_MIGRATIONS", "yes")
      assert MigrationGate.skip?()
    end

    test "EZAGENT_SKIP_MIGRATIONS=0 does NOT skip when prod (truthy-only override)" do
      System.put_env("MIX_ENV", "prod")
      System.put_env("EZAGENT_SKIP_MIGRATIONS", "0")
      refute MigrationGate.skip?()
    end

    test "EZAGENT_SKIP_MIGRATIONS=garbage does NOT skip when prod" do
      System.put_env("MIX_ENV", "prod")
      System.put_env("EZAGENT_SKIP_MIGRATIONS", "anything")
      refute MigrationGate.skip?()
    end
  end
end
