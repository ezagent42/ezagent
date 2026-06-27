defmodule EzagentPluginProtocolApi.OpenAI.DefaultAgentTest do
  @moduledoc """
  P2 — the OpenAI `/v1/chat/completions` DEFAULT-agent path points at
  `py_default` (the echo.py py-agent that replaces the deleted echo default agent).

  This asserts the code that CHANGED in P2: a request whose API key carries no
  `target_agent` falls back to `ChatCompletionsPlug.default_agent_uri/0`, which must
  now resolve to `entity://system/agent/py_default`, and the plug's default
  flavor-registration re-points to the `py` flavor (NOT `echo`).

  The LIVE HTTP round-trip against a seeded py_default subprocess is exercised
  in the Phase 3 world E2E (protocol_api carries no plugin→py dep, and
  `after_boot` seeds do not land in this plugin's isolated test app — so a live
  py_default cannot exist in a protocol_api unit test). See the PR for the P2/P3
  split rationale.
  """

  use ExUnit.Case, async: true

  alias EzagentPluginProtocolApi.OpenAI.ChatCompletionsPlug

  test "default_agent_uri/0 resolves to py_default (was the echo default)" do
    assert URI.to_string(ChatCompletionsPlug.default_agent_uri()) ==
             "entity://system/agent/py_default"
  end

  test "default-agent flavor re-registration targets the py flavor (was echo)" do
    # The plug auto-registers the default agent's flavor attribute so the
    # AgentModuleResolver can find its Kind module. It must register `py`.
    assert ChatCompletionsPlug.default_agent_flavor() == "py"
  end
end
