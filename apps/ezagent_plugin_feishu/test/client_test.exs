defmodule EzagentPluginFeishu.ClientTest do
  @moduledoc """
  P1 test-supplement (security triage) — outbound send failure handling
  (priority 3c). `EzagentPluginFeishu.Client` had 4.76% coverage before
  this PR and uses raw `:httpc` with no injectable transport seam (no
  Bypass/mock-HTTP dependency in this repo), so hitting the real Lark
  Open API is out of scope for a unit/contract test — and the task rules
  say do NOT hit real Feishu here.

  What IS deterministically testable without a network call: the
  `credentials_not_configured` fail-closed path. In test env there is no
  `feishu.yaml` (`EzagentPluginFeishu.Client.init/1` logs a warning and
  starts with `app_id: nil`), so EVERY outbound operation must reject
  before attempting any HTTP call — this is exactly the "outbound send
  failure handling" contract: an unconfigured/broken client fails
  CLOSED (a clear `{:error, :credentials_not_configured}`) rather than
  crashing the caller or silently no-op-succeeding.
  """

  use ExUnit.Case, async: false

  alias EzagentPluginFeishu.Client

  test "status/0 reports NOT configured in test env (no feishu.yaml)" do
    assert %{configured: false, token_minted: false} = Client.status()
  end

  test "send_text/2 fails closed with :credentials_not_configured (no HTTP attempted)" do
    assert {:error, :credentials_not_configured} = Client.send_text("oc_test_chat", "hello")
  end

  test "send_image/2 fails closed with :credentials_not_configured" do
    assert {:error, :credentials_not_configured} = Client.send_image("oc_test_chat", "img_key")
  end

  test "send_file/2 fails closed with :credentials_not_configured" do
    assert {:error, :credentials_not_configured} = Client.send_file("oc_test_chat", "file_key")
  end

  test "upload_image/1 fails closed with :credentials_not_configured" do
    assert {:error, :credentials_not_configured} = Client.upload_image("/tmp/does-not-matter.png")
  end

  test "upload_file/2 fails closed with :credentials_not_configured" do
    assert {:error, :credentials_not_configured} =
             Client.upload_file("/tmp/does-not-matter.bin", "name.bin")
  end

  test "download_resource/4 fails closed with :credentials_not_configured" do
    assert {:error, :credentials_not_configured} =
             Client.download_resource("om_1", "file_key", "file", "name.bin")
  end

  test "peek_token/0 fails closed with :credentials_not_configured (no token minted)" do
    assert {:error, :credentials_not_configured} = Client.peek_token()
  end

  test "react/2 does NOT fail closed the same way — it bypasses the GenServer and hits peek_token directly" do
    # react/2 (Phase 6 PR 17) deliberately routes around the Client
    # mailbox via peek_token/0 for latency reasons (see moduledoc). Pin
    # that it still ends up at the SAME fail-closed outcome via a
    # different code path, so a future refactor of the "fast path" can't
    # silently reintroduce a network call when unconfigured.
    assert {:error, :credentials_not_configured} = Client.react("om_1", "OK")
  end
end
