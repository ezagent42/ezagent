defmodule Ezagent.Runtime.PidFileUriBodyTest do
  @moduledoc """
  URI-body round-trip tests for `Ezagent.Runtime.PidFile` (Task 2, SPEC
  `2026-06-25-sidecar-erlexec-runtime.md` §3.4).

  The pid-file body gains a 3rd line — `URI.to_string(key)` — so that
  NON-`entity://` keys (notably feishu's `system://feishu/ws`) round-trip.
  The legacy filename reverse-parse (`agent_uri_from_filename/1`) only
  understands `entity://ws/agent/name`, so a `system://` key cannot be
  recovered from the sanitised filename — line 3 is its ONLY source.

  Invariant (feishu): a non-`entity` entry missing line 3 is a recoverable
  SKIP, NOT a garbage-delete — silently dropping it would drop a feishu
  orphan.
  """

  use ExUnit.Case, async: false

  alias Ezagent.Runtime.PidFile

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "ezagent-pidfile-uribody-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    prev_home = System.get_env("EZAGENT_HOME")
    prev_profile = System.get_env("EZAGENT_PROFILE")
    System.put_env("EZAGENT_HOME", tmp)
    System.put_env("EZAGENT_PROFILE", "pidfile-uribody-test")

    on_exit(fn ->
      if prev_home,
        do: System.put_env("EZAGENT_HOME", prev_home),
        else: System.delete_env("EZAGENT_HOME")

      if prev_profile,
        do: System.put_env("EZAGENT_PROFILE", prev_profile),
        else: System.delete_env("EZAGENT_PROFILE")

      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  describe "write/3 + enumerate/1 — non-entity key round-trip via line-3 body" do
    test "a system://feishu/ws key round-trips to the exact %URI{}" do
      key = Ezagent.URI.system("feishu", "ws")
      own_pid = String.to_integer(System.pid())

      :ok = PidFile.write("feishu-ws", key, own_pid)
      [entry] = PidFile.enumerate("feishu-ws")

      # Exact struct equality — this also pins canonical (authority: nil)
      # parsing of line 3 (Ezagent.URI.parse, not stdlib URI.parse which
      # would yield authority: "feishu").
      assert entry.agent_uri == key
      assert %URI{} = entry.agent_uri
      assert entry.os_pid == own_pid
      assert is_integer(entry.start_seconds)
    end

    test "the body file carries the URI on line 3" do
      key = Ezagent.URI.system("feishu", "ws")
      own_pid = String.to_integer(System.pid())

      :ok = PidFile.write("feishu-ws", key, own_pid)
      path = PidFile.file_path("feishu-ws", key)
      body = File.read!(path)

      lines = String.split(body, "\n", trim: true)
      assert length(lines) == 3
      assert List.last(lines) == URI.to_string(key)
    end
  end

  describe "write/3 + enumerate/1 — legacy entity round-trip still works" do
    test "a 3-line entity:// file round-trips via the body URI" do
      key = Ezagent.URI.new!("entity://team-alpha/agent/cc_demo")
      own_pid = String.to_integer(System.pid())

      :ok = PidFile.write("cc", key, own_pid)
      [entry] = PidFile.enumerate("cc")

      assert entry.agent_uri == key
    end

    test "a legacy 2-line entity:// file falls back to the filename parse" do
      key = Ezagent.URI.new!("entity://team-alpha/agent/cc_legacy")
      own_pid = String.to_integer(System.pid())
      # Hand-write the OLD 2-line format (no line 3).
      path = PidFile.file_path("cc", key)
      File.write!(path, "#{own_pid}\n0\n")

      [entry] = PidFile.enumerate("cc")
      assert entry.agent_uri == key
    end
  end

  describe "feishu invariant — missing line 3 on a non-entity subdir is a SKIP" do
    test "a non-entity file missing line 3 is skipped, NOT deleted" do
      # A feishu-ws pid file whose body lacks line 3. Its key cannot be
      # recovered from the sanitised filename (only entity:// can), so it
      # must be SKIPPED (recoverable) — never blind-deleted as garbage.
      dir = PidFile.dir("feishu-ws")
      # Filename does NOT parse as entity_<ws>_agent_<name>.
      path = Path.join(dir, "system_feishu_ws.pid")
      own_pid = String.to_integer(System.pid())
      File.write!(path, "#{own_pid}\n0\n")

      assert [] = PidFile.enumerate("feishu-ws")
      # The crucial assertion: the file is NOT deleted.
      assert File.exists?(path)
    end

    test "a truly-unparseable file (bad pid/start) is still deleted" do
      dir = PidFile.dir("feishu-ws")
      path = Path.join(dir, "garbage.pid")
      File.write!(path, "not a pid file\n")

      assert [] = PidFile.enumerate("feishu-ws")
      refute File.exists?(path)
    end
  end
end
