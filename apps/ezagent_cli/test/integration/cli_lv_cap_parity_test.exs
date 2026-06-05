defmodule EzagentCli.Integration.CliLvCapParityTest do
  @moduledoc """
  Phase 7 PR 34 invariant — V3.4: a non-admin user invoking actions via
  CLI (token-bound) hits CapBAC with caps derived from the SAME
  function as the LV surface, so authz decisions are deterministically
  identical for the same user.

  ## Why this matters

  CLI and LV are two separate auth surfaces. If they diverge on caps
  resolution, an action a user can do via LV becomes impossible via
  CLI (or vice versa) — breaking the "CLI ↔ LV same-server invariant"
  (Decision #130). The structural reason this works today is that
  BOTH paths derive caps from `Ezagent.Identity.list_caps_for/1` (LV
  reads it on mount; CLI reads it via `Ezagent.Entity.authenticate/2`
  on the bearer-token verify path).

  ## PR #142 update

  CLI token storage moved from `users.cli_token` (per-user-only field)
  to `entity_tokens` (entity-agnostic table). Verify is via
  `Ezagent.Entity.Token.verify/2` rather than `Users.lookup_by_cli_token/1`.

  `Entity.authenticate/2` dispatches by URI host — `user` → password
  (bcrypt against `users.password_hash`), `agent` → token (against
  `entity_tokens`). The parity invariant we're guarding is unchanged:
  whichever path lands a user/agent in the running runtime, caps come
  from `Ezagent.Identity.list_caps_for/1` so the same principal sees
  the same cap set across CLI + LV.

  ## What the test asserts

  1. A minted token verifies back to the same agent URI it was
     minted for (token path).
  2. A user URI's caps via `Entity.authenticate` (password) and via
     `list_caps_for` (LV mount) converge on the same MapSet
     (V3.4 parity).
  3. Invalid tokens cleanly return `{:error, :invalid_credentials}`
     (the path CLI Exec converts to exit code 4).
  4. Non-admin agents do NOT receive admin wildcard caps via token
     (no privilege elevation bug).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Capability, Entity, Users}
  alias Ezagent.Entity.Token

  setup do
    suffix = "parity-#{System.unique_integer([:positive])}"
    user_uri = URI.new!("entity://team-alpha/user/#{suffix}")
    agent_uri = URI.new!("entity://team-alpha/agent/cc_#{suffix}")
    {:ok, %{user_uri: user_uri, agent_uri: agent_uri, suffix: suffix}}
  end

  defp create_user_with_caps(uri, extra_caps) when is_list(extra_caps) do
    {:ok, _decoded} = Users.create(URI.to_string(uri), "test-password", extra_caps)
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
    :ok
  end

  test "minted token verifies back to its agent URI", %{agent_uri: agent_uri} do
    {plain, _row} = Token.mint(agent_uri, label: "parity-test")

    assert {:ok, %{caps: _}} = Entity.authenticate(agent_uri, plain)
  end

  test "CLI-resolved caps == LV-resolved caps for the same user (V3.4 parity)",
       %{user_uri: user_uri} do
    workspace_cap = %Capability{
      kind: :workspace,
      behavior: :any,
      instance: :any,
      # Phase 9 PR-3 (SPEC v3 §4): explicit workspace scope.
      workspace_uri: URI.new!("workspace://team-alpha"),
      granted_by: Ezagent.URI.new!("entity://system/user/admin"),
      granted_at: ~U[2026-05-18 00:00:00Z]
    }

    :ok = create_user_with_caps(user_uri, [workspace_cap])

    # CLI path: bcrypt → Entity.authenticate → caps
    {:ok, %{caps: cli_caps}} = Entity.authenticate(user_uri, "test-password")

    # LV path: session cookie → URI → list_caps_for (same function
    # Entity.authenticate calls under the hood)
    lv_caps = Ezagent.Identity.list_caps_for(user_uri)

    # The two surfaces MUST converge on the same MapSet — that's the
    # V3.4 parity invariant. Both go through list_caps_for/1, so this
    # is structurally guaranteed today; the test pins the contract so
    # any future refactor that diverges the lookup paths fails CI.
    assert cli_caps == lv_caps,
           "CLI-derived caps != LV-derived caps for the same user — " <>
             "the two auth surfaces have diverged on caps resolution. " <>
             "Decision #130 (CLI ↔ LV same-server invariant) violated. " <>
             "CLI got #{MapSet.size(cli_caps)} caps; LV got #{MapSet.size(lv_caps)} caps."
  end

  test "invalid token returns :error (the path CLI Exec converts to exit code 4)",
       %{agent_uri: agent_uri} do
    {_real, _row} = Token.mint(agent_uri)

    fake_token = "not-a-real-token-#{System.unique_integer([:positive])}"
    assert {:error, :invalid_credentials} = Entity.authenticate(agent_uri, fake_token)
  end

  test "non-admin agent token does NOT resolve to admin wildcard cap",
       %{agent_uri: agent_uri} do
    {plain, _row} = Token.mint(agent_uri)

    {:ok, %{caps: caps}} = Entity.authenticate(agent_uri, plain)

    refute Enum.any?(caps, fn c ->
             c.kind == :any and c.behavior == :any and c.instance == :any
           end),
           "non-admin agent resolved to admin wildcard cap via token — " <>
             "auth elevation bug; only entity://system/user/admin should hold this cap"
  end
end
