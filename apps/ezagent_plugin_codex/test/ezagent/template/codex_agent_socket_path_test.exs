defmodule Ezagent.PluginCodex.Template.CodexAgentSocketPathTest do
  @moduledoc """
  Regression for the codex app-server unix-socket SUN_LEN bug (2026-06-01).

  `default_app_server_socket_path/1` previously embedded the full sanitized
  agent URI, producing a ~135-byte path for orchestrator-spawned workers —
  over macOS's unix-domain `SUN_LEN` (~104). `codex app-server --listen
  unix://<path>` then failed (`path must be shorter than SUN_LEN`), the
  app-server exited status 1, and the codex worker never round-tripped.
  The fix uses a short deterministic hash for the socket dir.
  """

  use ExUnit.Case, async: true

  alias Ezagent.PluginCodex.Template.CodexAgent

  # The macOS limit is 104; Linux is 108. Stay safely under the smaller.
  @sun_len 104

  test "socket path stays under SUN_LEN even for a long orchestrator worker URI" do
    # The exact shape that broke it: codex_worker-<slot>-<32 hex>--<session>.
    uri =
      URI.new!(
        "entity://agent/system/codex_worker-cx-52967c238ab935521dd83083cce7e787--e2e-orch15"
      )

    path = CodexAgent.default_app_server_socket_path(uri)

    assert byte_size(path) < @sun_len,
           "codex app-server socket path must be < #{@sun_len} bytes (unix SUN_LEN) — " <>
             "got #{byte_size(path)}: #{path}"

    assert String.ends_with?(path, "/app-server.sock")
  end

  test "socket path is deterministic (respawn + the 4 consumers must agree)" do
    uri = URI.new!("entity://agent/system/codex_worker-a-deadbeef--sess")
    assert CodexAgent.default_app_server_socket_path(uri) ==
             CodexAgent.default_app_server_socket_path(uri)
  end

  test "distinct agent URIs get distinct socket dirs" do
    a = CodexAgent.default_app_server_socket_path(URI.new!("entity://agent/system/codex_a--s"))
    b = CodexAgent.default_app_server_socket_path(URI.new!("entity://agent/system/codex_b--s"))
    assert Path.dirname(a) != Path.dirname(b)
  end
end
