defmodule Ezagent.Session.Participants do
  @moduledoc """
  Operator-facing entry for session participant lifecycle (F7 PR-A).

  ONE dispatch path shared by the CLI (`mix ezagent.session.remove_participant`
  / `.list_participants`) and the world UI conversation surface — the
  "CLI/UI 同源派生" convention (Allen 2026-05-25). Both surfaces call
  `remove_participant/2` / `list_participants/1`; neither re-implements the
  authorization or the dispatch.

  `remove_participant/2` dispatches the isomorphic `session.remove_participant`
  action (`Ezagent.Behavior.Session`) under the CALLER's real caps (CapBAC at
  the chokepoint). For a self-leave (`caller == participant`) it first provisions
  the JIT self-leave authority (SPEC §3.3) so the caller clears the chokepoint.

  PR-A SCOPE: the non-spawned (user / invited-agent) removal is live; a spawned
  worker returns `{:error, :spawned_participant_teardown_pending_pr_b}` (the
  cap-model teardown change is PR-B).
  """

  alias Ezagent.Behavior.Session.Membership
  alias Ezagent.Invocation

  @typedoc "Result of a successful non-spawned participant removal."
  @type removal :: %{
          status: :removed,
          torn_down: :membership_only,
          deleted_rules: non_neg_integer(),
          repointed_rules: non_neg_integer()
        }

  @doc """
  Remove `participant_uri` from `session_uri` on behalf of `caller_uri`.

  The caller's caps are resolved via `Ezagent.Identity.list_caps_for/1` (the same
  authority the operator holds everywhere). The owner holds the create-time
  `:remove_participant` cap; a self-leaver gets a JIT self-scoped cap first.

  Returns the `removal/0` map, `:already_removed`, or `{:error, reason}`
  (`:unauthorized`, `:spawned_participant_teardown_pending_pr_b`, …).
  """
  @spec remove_participant(URI.t(), URI.t(), URI.t()) ::
          {:ok, removal() | :already_removed} | {:error, term()}
  def remove_participant(%URI{} = session_uri, %URI{} = participant_uri, %URI{} = caller_uri) do
    # Self-leave (§3.3): mint the JIT self-scoped cap so a participant who holds
    # only the participation tier clears the dispatch chokepoint.
    if caller_uri == participant_uri do
      _ = Membership.provision_self_leave_authority(session_uri, caller_uri)
    end

    caps = Ezagent.Identity.list_caps_for(caller_uri)

    result =
      Invocation.dispatch(%Invocation{
        target: Ezagent.URI.with_action(session_uri, :session, :remove_participant),
        mode: :call,
        args: %{participant: participant_uri},
        ctx: %{caller: caller_uri, caps: caps, reply: {:caller_inbox, self()}}
      })

    case result do
      {:ok, %{status: :removed} = removal} -> {:ok, removal}
      {:ok, :already_removed} -> {:ok, :already_removed}
      {:ok, other} -> {:ok, other}
      {:error, _reason} = err -> err
      other -> {:error, {:unexpected_remove_participant_result, other}}
    end
  end

  @doc """
  List the current participant URIs of `session_uri` (reads the live persisted
  members slice). Used to verify cross-op convergence — a UI remove is reflected
  in a subsequent CLI `list`, and vice-versa (both read the SAME slice).
  """
  @spec list_participants(URI.t()) :: [URI.t()]
  def list_participants(%URI{} = session_uri) do
    Ezagent.Entity.Session.session_member_uris(session_uri)
  end
end
