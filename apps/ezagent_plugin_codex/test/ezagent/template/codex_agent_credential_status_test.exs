defmodule Ezagent.PluginCodex.Template.CodexAgentCredentialStatusTest do
  @moduledoc """
  #160 — `CodexAgent.credential_status/2` maps the codex probe onto the normalized
  enum (present→:authenticated, absent→:missing, garbled→:unknown), always with
  `expires_at: nil` (codex has no readable expiry). codex-remote delegates.
  """
  use ExUnit.Case, async: true

  alias Ezagent.PluginCodex.Template.{CodexAgent, CodexRemoteAgent}

  setup do
    home = Path.join(System.tmp_dir!(), "codex-tc-cred-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf(home) end)
    {:ok, home: home}
  end

  test "present auth.json → :authenticated, expires_at nil", %{home: home} do
    File.write!(Path.join(home, "auth.json"), Jason.encode!(%{"tokens" => %{"access_token" => "a"}}))
    assert %{status: :authenticated, expires_at: nil} = CodexAgent.credential_status(home)
  end

  test "absent → :missing with a login hint", %{home: home} do
    assert %{status: :missing, detail: detail} = CodexAgent.credential_status(home)
    assert detail =~ "login"
  end

  test "garbled → :unknown", %{home: home} do
    File.write!(Path.join(home, "auth.json"), "{not json")
    assert %{status: :unknown} = CodexAgent.credential_status(home)
  end

  test "codex-remote delegates identically", %{home: home} do
    File.write!(Path.join(home, "auth.json"), Jason.encode!(%{"tokens" => %{"access_token" => "a"}}))
    assert CodexRemoteAgent.credential_status(home) == CodexAgent.credential_status(home)
  end
end
