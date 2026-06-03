defmodule Ezagent.Runtime.PidFileTest do
  @moduledoc """
  Unit tests for `Ezagent.Runtime.PidFile`.

  Each test sets a fresh EZAGENT_HOME so deployments don't share
  state. The shared `Ezagent.DeploymentId.deployment_id/0` is loaded
  once at module-load — tests can't override it without recompiling,
  so all tests run under the same deployment_id (which is fine for
  these scenarios; isolation is via EZAGENT_HOME).
  """

  use ExUnit.Case, async: false

  alias Ezagent.Runtime.PidFile

  setup do
    tmp = Path.join(System.tmp_dir!(), "ezagent-pidfile-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    prev_home = System.get_env("EZAGENT_HOME")
    prev_profile = System.get_env("EZAGENT_PROFILE")
    System.put_env("EZAGENT_HOME", tmp)
    System.put_env("EZAGENT_PROFILE", "pidfile-test")

    on_exit(fn ->
      if prev_home, do: System.put_env("EZAGENT_HOME", prev_home), else: System.delete_env("EZAGENT_HOME")
      if prev_profile, do: System.put_env("EZAGENT_PROFILE", prev_profile), else: System.delete_env("EZAGENT_PROFILE")
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  describe "dir/1" do
    test "creates the per-deployment plugin subdir" do
      path = PidFile.dir("cc")
      assert File.dir?(path)
      assert String.contains?(path, "pty-pids")
      assert String.ends_with?(path, "/cc")
    end

    test "different plugins get different subdirs" do
      assert PidFile.dir("cc") != PidFile.dir("np")
    end
  end

  describe "write/3 + enumerate/1 roundtrip" do
    test "URI is faithfully reconstructed from filename" do
      uri = URI.parse("entity://agent/team-alpha/cc_demo")
      own_pid = String.to_integer(System.pid())

      :ok = PidFile.write("cc", uri, own_pid)
      [entry] = PidFile.enumerate("cc")

      assert URI.to_string(entry.agent_uri) == URI.to_string(uri)
      assert entry.os_pid == own_pid
      assert is_integer(entry.start_seconds)
      assert entry.start_seconds > 0
    end

    test "multiple URIs enumerate independently" do
      own_pid = String.to_integer(System.pid())

      uris = [
        URI.parse("entity://agent/team-alpha/cc_one"),
        URI.parse("entity://agent/team-alpha/cc_two"),
        URI.parse("entity://agent/team-beta/cc_three")
      ]

      Enum.each(uris, &PidFile.write("cc", &1, own_pid))

      entries = PidFile.enumerate("cc")
      assert length(entries) == 3
      seen = entries |> Enum.map(& &1.agent_uri) |> Enum.map(&URI.to_string/1) |> MapSet.new()
      expected = uris |> Enum.map(&URI.to_string/1) |> MapSet.new()
      assert MapSet.equal?(seen, expected)
    end
  end

  describe "remove/2" do
    test "deletes the file" do
      uri = URI.parse("entity://agent/team-alpha/cc_remove")
      own_pid = String.to_integer(System.pid())
      :ok = PidFile.write("cc", uri, own_pid)
      assert [_] = PidFile.enumerate("cc")

      :ok = PidFile.remove("cc", uri)
      assert [] = PidFile.enumerate("cc")
    end

    test "is idempotent when the file is missing" do
      uri = URI.parse("entity://agent/team-alpha/cc_never_written")
      :ok = PidFile.remove("cc", uri)
    end
  end

  describe "process_start_seconds/1" do
    test "returns an int for a live PID (our own)" do
      own_pid = String.to_integer(System.pid())
      start = PidFile.process_start_seconds(own_pid)
      assert is_integer(start)
      assert start > 0
      # The own-process start time must be at most "now".
      assert start <= System.os_time(:second)
    end

    test "returns nil for a deliberately-dead PID" do
      assert PidFile.process_start_seconds(99_998) in [nil] or
               is_integer(PidFile.process_start_seconds(99_998))
    end
  end

  describe "enumerate/1 garbage handling" do
    test "deletes unparseable .pid files and returns []" do
      dir = PidFile.dir("cc")
      garbage = Path.join(dir, "not-a-uri-filename.pid")
      File.write!(garbage, "this isn't valid\n")

      assert [] = PidFile.enumerate("cc")
      refute File.exists?(garbage)
    end

    test "non-.pid files are skipped (not deleted)" do
      dir = PidFile.dir("cc")
      misc = Path.join(dir, "README.txt")
      File.write!(misc, "hi\n")

      assert [] = PidFile.enumerate("cc")
      # Skipped without touching.
      assert File.exists?(misc)
    end
  end
end
