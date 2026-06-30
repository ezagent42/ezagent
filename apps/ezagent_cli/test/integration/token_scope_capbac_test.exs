defmodule EzagentCli.Integration.TokenScopeCapbacTest do
  @moduledoc """
  Phase 3 ③ T9 — token-scope security exhibit (design principle **P6**:
  the security claim is proven by an invariant test, not by "the suite
  is green").

  ## Threat model this pins

  pm / dev are cc agents. They act by running `mix ezagent <verb>` with
  their OWN bearer token (`EZAGENT_USER_TOKEN`). The runtime path is:

      token string
        → EzagentCli.Exec.exec(argv, token:, entity_uri:)
        → Ezagent.Entity.authenticate/2        (verify + caps lookup)
        → Process caller override {uri, caps}  (THIS agent's caps only)
        → Invocation.dispatch/1
        → Kind.Runtime authz_check (step 5.5)   (CapBAC gate)

  The security property: an agent's token grants ONLY that agent's
  least-priv caps. It can NOT self-mint, can NOT fall back to admin, and
  can NOT escalate by invoking a privileged verb its caps don't cover.
  The existing `CliRuntimeSameServerInvariantTest` proves the POSITIVE
  (admin token → grant_cap succeeds); this file pins the NEGATIVE — the
  one that actually closes the privilege-escalation hole.

  ## Why the full Exec path (not just `authenticate/2`)

  `CliLvCapParityTest` already asserts token → caps scoping at the
  `authenticate/2` seam. This test goes one layer deeper — through the
  SAME `EzagentCli.Exec.exec/2` entry the `:rpc.call` from the operator
  CLI lands on — so the token verify, the caller override, the dispatch,
  AND the CapBAC gate are all in the loop. That is what "faces
  production" means for the agent-runs-`mix ezagent` flow.
  """

  use EzagentCore.DataCase, async: false

  # Cross-tier: drives EzagentCli.Exec + identity Token + Users; resolves
  # only in the umbrella.
  @moduletag :umbrella_only

  alias Ezagent.{Capability, Entity, Users}
  alias Ezagent.Entity.Token

  defp create_user(uri_str, caps) do
    {:ok, _decoded} = Users.create(uri_str, nil, caps)
    uri = Ezagent.URI.new!(uri_str)
    {:ok, pid} = Ezagent.SpawnRegistry.spawn(uri)
    {uri, pid}
  end

  defp grantable_cap(granted_by) do
    Capability.cap(
      :workspace,
      Ezagent.World.Behavior.Layout,
      :manage,
      Ezagent.URI.new!("workspace://team-alpha"),
      Ezagent.URI.new!("workspace://team-alpha")
    )
    |> Map.put(:granted_by, granted_by)
    |> Map.put(:granted_at, DateTime.utc_now())
  end

  defp cap_present?(pid, cap) do
    target = Capability.identity_key(cap)

    :sys.get_state(pid, 500).state.identity.state.caps
    |> Enum.any?(&(Capability.identity_key(&1) == target))
  end

  describe "least-priv token cannot escalate via `mix ezagent user grant_cap`" do
    test "CapBAC denies the grant; the subject never receives the cap" do
      suffix = System.unique_integer([:positive])

      # Caller: a real entity with EMPTY caps (least-priv agent persona).
      caller_uri_str = "entity://team-alpha/user/lp_caller_#{suffix}"
      {caller_uri, _caller_pid} = create_user(caller_uri_str, [])

      # Subject the caller will *attempt* to grant a privileged cap to.
      subject_uri_str = "entity://team-alpha/user/lp_subject_#{suffix}"
      {_subject_uri, subject_pid} = create_user(subject_uri_str, [])

      # The privileged cap the least-priv caller tries to confer. Forge
      # `granted_by` as the caller itself — the most generous reading of
      # "what an agent could try to self-author".
      cap = grantable_cap(caller_uri)
      cap_json = Jason.encode!(Capability.to_map(cap))

      refute cap_present?(subject_pid, cap),
             "precondition: subject must start without the cap"

      # Real minted token for the least-priv caller — NO process-dict
      # shortcut; the token is verified inside Exec.exec/2.
      {plain_token, _row} = Token.mint(caller_uri, label: "t9-token-scope")

      result =
        EzagentCli.Exec.exec(
          [
            "user",
            "grant_cap",
            "--user",
            subject_uri_str,
            "--cap",
            cap_json
          ],
          token: plain_token,
          entity_uri: caller_uri_str
        )

      # 1. The verb is refused — CapBAC gate, not a silent success.
      assert result.exit_code != 0,
             "least-priv token escalated via grant_cap (exit 0) — " <>
               "CapBAC gate bypassed. output=#{inspect(result.output)}"

      # 2. The real security property: the escalation had NO effect. The
      #    subject's identity caps are unchanged — no admin fallback, no
      #    self-mint, no partial write.
      refute cap_present?(subject_pid, cap),
             "subject received a cap a least-priv caller had no authority " <>
               "to grant — privilege escalation through the CLI token path"
    end
  end

  describe "token resolves to the entity's OWN caps only (no admin wildcard)" do
    test "a non-admin token never yields the admin genesis cap" do
      suffix = System.unique_integer([:positive])
      uri_str = "entity://team-alpha/user/scope_#{suffix}"

      # Give the entity a single narrow cap so we also prove the resolved
      # set is exactly what was granted — not a superset.
      narrow = grantable_cap(Ezagent.URI.new!("entity://system/user/admin"))
      {uri, _pid} = create_user(uri_str, [narrow])

      {plain_token, _row} = Token.mint(uri, label: "t9-scope-narrow")
      {:ok, %{caps: caps}} = Entity.authenticate(uri, plain_token)

      refute Enum.any?(caps, fn c ->
               c.kind == :any and c.behavior == :any and c.instance == :any
             end),
             "non-admin token resolved to the admin genesis wildcard — " <>
               "auth elevation; only entity://system/user/admin holds it"

      assert Enum.any?(caps, &(Capability.identity_key(&1) == Capability.identity_key(narrow))),
             "the entity's own granted cap is missing from the resolved set"
    end
  end

  describe "no-token CLI call is refused (no ambient admin authority)" do
    test "Exec.exec/2 with no token returns exit 4, never runs the verb" do
      result =
        EzagentCli.Exec.exec(
          ["user", "grant_cap", "--user", "entity://team-alpha/user/whoever", "--cap", "{}"],
          []
        )

      assert result.exit_code == 4
      assert result.output =~ "authentication"
    end
  end
end
