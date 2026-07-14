defmodule EzagentWeb.HelloDelegationContinuationTest do
  use ExUnit.Case, async: false

  alias EzagentWeb.HelloDelegationContinuation

  setup do
    original = Application.get_env(:ezagent_web, :hello_delegation_max_age)

    on_exit(fn ->
      if original,
        do: Application.put_env(:ezagent_web, :hello_delegation_max_age, original),
        else: Application.delete_env(:ezagent_web, :hello_delegation_max_age)
    end)

    :ok
  end

  test "round-trips a bounded hello instruction with a nonce" do
    session = Ezagent.URI.session("demo", :hello, "launch")
    token = HelloDelegationContinuation.sign(session, "Ship the homepage")

    assert {:ok, payload} = HelloDelegationContinuation.verify(token)
    assert payload.session_uri == session
    assert payload.instruction == "Ship the homepage"
    assert is_binary(payload.nonce) and byte_size(payload.nonce) >= 16
  end

  test "rejects tampering, expiry, non-hello sessions, and blank instructions" do
    session = Ezagent.URI.session("demo", :hello, "launch")
    token = HelloDelegationContinuation.sign(session, "Ship it")

    assert {:error, :invalid_token} = HelloDelegationContinuation.verify(token <> "x")

    Application.put_env(:ezagent_web, :hello_delegation_max_age, -1)
    assert {:error, :invalid_token} = HelloDelegationContinuation.verify(token)

    assert_raise ArgumentError, fn ->
      HelloDelegationContinuation.sign(Ezagent.URI.session("demo", :default, "main"), "Ship it")
    end

    assert_raise ArgumentError, fn -> HelloDelegationContinuation.sign(session, "  ") end
  end
end
