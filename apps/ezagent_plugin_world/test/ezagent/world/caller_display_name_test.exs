defmodule Ezagent.World.CallerDisplayNameTest do
  @moduledoc """
  The World nav account menu label (`data-caller.display_name`) is read by the
  React island EXACTLY ONCE at mount (`WorldRenderer.mounted()` never re-reads
  `data-caller`). So the value emitted by the SYNCHRONOUS bootstrap payload at
  `mount/3` is what the top-right menu shows for the whole session if it loses
  the mount-vs-async-load race.

  Regression for the prod anomaly where a cold `/sessions` mount rendered the
  raw `entity://ezagent/user/<handle>` URI in the account menu instead of the
  profile display name:

    * the INITIAL `bootstrap_caller_payload/2` must already carry the resolved
      `entity_profiles.display_name` (first paint correct — no race), and
    * with no profile row, the fallback must be the URI HANDLE (last path
      segment), NEVER the raw `entity://…` URI.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.World.LiveStateBuilder

  setup do
    ws_name = "dispname-#{System.unique_integer([:positive])}"
    workspace = Ezagent.URI.workspace(ws_name)
    {:ok, ws_name: ws_name, workspace: workspace}
  end

  test "initial /sessions payload carries the profile display_name (first paint is correct)",
       %{ws_name: ws_name, workspace: workspace} do
    caller = Ezagent.URI.user(ws_name, "lin_yilun")

    {:ok, _profile} =
      Ezagent.Entity.Profile.upsert(%{
        entity_uri: URI.to_string(caller),
        display_name: "林懿伦",
        email: "lin-#{System.unique_integer([:positive])}@example.com"
      })

    payload = LiveStateBuilder.bootstrap_caller_payload(caller, workspace)

    assert payload["display_name"] == "林懿伦"
    # Never the raw URI, even in the bounded bootstrap payload.
    refute payload["display_name"] == URI.to_string(caller)
  end

  test "without a profile, the bootstrap display_name falls back to the handle, not the raw URI",
       %{ws_name: ws_name, workspace: workspace} do
    caller = Ezagent.URI.user(ws_name, "lin_yilun")

    payload = LiveStateBuilder.bootstrap_caller_payload(caller, workspace)

    # The URI's identity handle (last path segment), matching what the official
    # site shows — never the truncated raw `entity://…` URI.
    assert payload["display_name"] == Ezagent.URI.name!(caller)
    assert payload["display_name"] == "lin_yilun"
    refute payload["display_name"] == URI.to_string(caller)
  end
end
