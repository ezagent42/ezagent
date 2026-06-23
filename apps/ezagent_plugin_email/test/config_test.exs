defmodule Ezagent.Email.ConfigTest do
  use ExUnit.Case, async: false
  alias Ezagent.Email.Config

  setup do
    on_exit(fn ->
      System.delete_env("EZAGENT_EMAIL_PULL_URL")
      System.delete_env("EZAGENT_EMAIL_PULL_TOKEN")
      System.delete_env("EZAGENT_EMAIL_BACKEND")
    end)
  end

  test "env vars supply config" do
    System.put_env("EZAGENT_EMAIL_PULL_URL", "https://w.example.dev")
    System.put_env("EZAGENT_EMAIL_PULL_TOKEN", "tok")
    assert {:ok, cfg} = Config.load()
    assert cfg["pull_url"] == "https://w.example.dev"
    assert cfg["pull_token"] == "tok"
    assert cfg["backend"] == "cf_worker"
  end

  test "blank/missing config → :inbox_not_configured" do
    assert {:error, :inbox_not_configured} = Config.load()
  end

  test "backend env override honored" do
    System.put_env("EZAGENT_EMAIL_PULL_URL", "https://w.example.dev")
    System.put_env("EZAGENT_EMAIL_PULL_TOKEN", "tok")
    System.put_env("EZAGENT_EMAIL_BACKEND", "imap")
    assert {:ok, %{"backend" => "imap"}} = Config.load()
  end
end
