defmodule Ezagent.Message.ActionableErrorTest do
  use ExUnit.Case, async: true

  alias Ezagent.Message.{ActionableError, Body}

  test "the initial catalog exposes stable recovery fields for all four known cases" do
    assert MapSet.new(ActionableError.kinds()) ==
             MapSet.new([
               :missing_credentials,
               :unauthorized,
               :quota_exceeded,
               :network_timeout,
               :unknown
             ])

    for kind <- [:missing_credentials, :unauthorized, :quota_exceeded, :network_timeout] do
      error = ActionableError.new(kind)

      assert is_binary(error["code"])
      assert error["layer"] in [1, 2, 3]
      assert is_binary(error["title"])
      assert is_binary(error["what_happened"])
      assert is_binary(error["impact"])
      assert is_binary(error["next_step"])
    end
  end

  test "a producer can attach repair and diagnostic metadata without changing the catalog code" do
    error =
      ActionableError.new(:missing_credentials,
        action_href: "/identities/agents/example/api-keys",
        detail: "provider=deepseek"
      )

    assert error["code"] == "agent.credentials_missing"

    assert error["action"] == %{
             "label" => "配置 API Key",
             "href" => "/identities/agents/example/api-keys"
           }

    assert error["detail"] == "provider=deepseek"
  end

  test "message body accessor accepts persisted string keys and internal atom keys" do
    error = ActionableError.new(:network_timeout)
    assert Body.actionable_error(%{actionable_error: error}) == error
    assert Body.actionable_error(%{"actionable_error" => error}) == error
    assert Body.actionable_error(%{text: "ok"}) == nil
  end
end
