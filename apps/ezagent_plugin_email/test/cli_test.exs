defmodule Mix.Tasks.Ezagent.EmailTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  test "send subcommand delivers and prints sent" do
    out =
      capture_io(fn ->
        Mix.Tasks.Ezagent.Email.run(["send", "--to", "d@ezagent.chat", "--subject", "S", "--body", "B"])
      end)

    assert out =~ "sent"
  end

  test "inbox subcommand exits non-zero with reason when unconfigured" do
    out =
      capture_io(:stderr, fn ->
        assert catch_exit(Mix.Tasks.Ezagent.Email.run(["inbox"])) == {:shutdown, 1}
      end)

    assert out =~ "inbox_not_configured"
  end
end
