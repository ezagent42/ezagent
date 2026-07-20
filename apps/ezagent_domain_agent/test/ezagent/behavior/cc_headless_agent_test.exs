defmodule Ezagent.ActionSet.CcHeadlessAgentTest do
  @moduledoc """
  G5 source 2 — `handle_cc_headless_sync_result/2` error branch replies with
  the STRUCTURED error payload (`Ezagent.Agent.ErrorSignal`), not hand-written
  prose. The success branch is untouched (raw assistant reply text).
  """

  use ExUnit.Case, async: true

  alias Ezagent.ActionSet.CcHeadlessAgent

  defp ctx(agent_uri) do
    %{
      read: fn
        :max_history, _ -> 40
        :conversation, _ -> []
        _, d -> d
      end,
      self_uri: agent_uri
    }
  end

  test "success replies with the raw assistant content (unchanged)" do
    agent_uri = Ezagent.URI.new!("entity://team-alpha/agent/cch_ok")
    session_uri = Ezagent.URI.new!("session://team-alpha/default/main")

    args = %{
      result: {:ok, %{content: "hello back", usage: %{total: 7}}},
      source_session: session_uri,
      user_text: "hello"
    }

    assert {:ok, %{ok: true, tokens: 7}, effects} =
             CcHeadlessAgent.handle_cc_headless_sync_result(args, ctx(agent_uri))

    assert {:set, :last_error, nil} in effects

    assert [{:dispatch, %Ezagent.Cmd{action: :send} = cmd}] =
             Enum.filter(effects, &match?({:dispatch, _}, &1))

    assert %Ezagent.Message{body: %{text: "hello back"}} = cmd.args.message
  end

  test "SDK error sets last_error + dispatches a structured error reply" do
    agent_uri = Ezagent.URI.new!("entity://team-alpha/agent/cch_err")
    session_uri = Ezagent.URI.new!("session://team-alpha/default/main")

    args = %{
      result: {:error, :sdk_sidecar_timeout},
      source_session: session_uri,
      user_text: "hello"
    }

    assert {:ok, %{ok: false, error: :sdk_sidecar_timeout}, effects} =
             CcHeadlessAgent.handle_cc_headless_sync_result(args, ctx(agent_uri))

    assert {:set, :last_error, :sdk_sidecar_timeout} in effects

    assert [{:dispatch, %Ezagent.Cmd{action: :send} = cmd}] =
             Enum.filter(effects, &match?({:dispatch, _}, &1))

    assert %Ezagent.Message{body: body} = cmd.args.message
    assert body.error == %{"reason" => ["sdk_sidecar_timeout"]}
    assert body.text == "[agent error] sdk_sidecar_timeout"
    assert body.attachments == []
  end

  test "tuple SDK error keeps args on the wire" do
    agent_uri = Ezagent.URI.new!("entity://team-alpha/agent/cch_err2")
    session_uri = Ezagent.URI.new!("session://team-alpha/default/main")

    args = %{
      result: {:error, {:sdk_sidecar_exit, 137}},
      source_session: session_uri,
      user_text: "hello"
    }

    assert {:ok, %{ok: false, error: :sdk_sidecar_exit}, effects} =
             CcHeadlessAgent.handle_cc_headless_sync_result(args, ctx(agent_uri))

    assert [{:dispatch, %Ezagent.Cmd{} = cmd}] =
             Enum.filter(effects, &match?({:dispatch, _}, &1))

    assert cmd.args.message.body.error == %{"reason" => ["sdk_sidecar_exit", 137]}
  end
end
