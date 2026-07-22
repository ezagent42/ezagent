defmodule EzagentCore.Invariants.MembersNotAuthorityProbes do
  @moduledoc "Probe definitions for the M-9 session-roster-is-not-authority gate."

  @probes [
    %{
      id: :p16,
      desc: "direct runtime slice read of a members projection",
      pattern: ~r/ctx\[:read\]\.\(:members/,
      allowlist: [
        # Session projection reads used for fan-out, lifecycle mutation, and
        # idempotent convergence after the cap gate has already authorized.
        "apps/ezagent_domain_session/lib/ezagent/behavior/session.ex",
        "apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex",
        "apps/ezagent_domain_session/lib/ezagent/behavior/session/route_provisioner.ex",
        # These two files are the cap-authenticated sole roster-writer seam.
        "apps/ezagent_domain_session/lib/ezagent/behavior/session/self_add.ex",
        "apps/ezagent_domain_session/lib/ezagent/behavior/session/self_add/effects.ex",
        # Workspace membership is a separate structural projection; workspace
        # authorization is not implemented by this session-membership program.
        "apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace.ex"
      ]
    },
    %{
      id: :p17,
      desc: "membership decision from Map.has_key?(members, subject)",
      pattern: ~r/Map\.has_key\?\(members\s*,/,
      allowlist: [
        # Post-authorize session projection/mutation and idempotency checks.
        "apps/ezagent_domain_session/lib/ezagent/behavior/session.ex",
        "apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex",
        # E2E and takeover convergence assertions, never authorization inputs.
        "apps/ezagent_domain_session/lib/ezagent/e2e/scenarios/agent_contract_g4.ex",
        "apps/ezagent_web/lib/ezagent_web/socialware/anon_takeover.ex"
      ]
    },
    %{
      id: :p18,
      desc: "roster authority construct inside a session authorization module",
      pattern: ~r/(?:ctx\[:read\]\.\(:members|Map\.has_key\?\(members\s*,|def\s+member\?\()/,
      allowlist: [],
      paths: [
        "apps/ezagent_domain_session/lib/ezagent/session/membership_predicate.ex",
        "apps/ezagent_domain_identity/lib/ezagent/session/member_receive.ex",
        "apps/ezagent_domain_session/lib/ezagent/behavior/socialware_publisher_read.ex",
        "apps/ezagent_domain_socialware/lib/ezagent/socialware/session_reads.ex"
      ]
    }
  ]

  @doc false
  def probes, do: @probes
end
