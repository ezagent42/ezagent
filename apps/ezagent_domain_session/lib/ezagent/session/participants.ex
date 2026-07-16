defmodule Ezagent.Session.Participants do
  @moduledoc """
  Operator-facing entry for session participant lifecycle (F7 PR-A).

  ONE dispatch path shared by the CLI (`mix ezagent.session.remove_participant`
  / `.list_participants`) and the world UI conversation surface — the
  "CLI/UI 同源派生" convention (Allen 2026-05-25). Both surfaces call
  `remove_participant/3` / `list_participants/1`; neither re-implements the
  authorization or the dispatch.

  `remove_participant/3` dispatches the isomorphic `session.remove_participant`
  action (`Ezagent.ActionSet.Session`) under the CALLER's ctx (`%{caller, caps}`),
  authorized at the chokepoint by `ctx.caps`. The surfaces own ctx CONSTRUCTION
  (the UI passes its live caps; the CLI builds an operator cap) — this module
  does NO persisted-caps read (cap_check_only_at_chokepoint p6). For a self-leave
  (`caller == participant`) it adds the inline self-scoped cap (SPEC §3.3) so the
  caller clears the chokepoint; the handler's identity gate then confirms
  `caller == participant`.

  Removal is isomorphic over participant type (F7 PR-A + PR-B): user / invited-
  agent removal is membership-only (`torn_down: :membership_only`); a worker the
  session SPAWNED is reaped (config-dir GC + termination + lineage forget) under
  the owner's `{:spawned_by, owner_uri}` teardown cap (`torn_down: :worker`, the
  PR-B cap-model change).
  """

  alias Ezagent.ActionSet.Session.Membership
  alias Ezagent.Invocation

  @typedoc "Caller dispatch context: the acting entity + its caps."
  @type ctx :: %{required(:caller) => URI.t(), optional(:caps) => Enumerable.t()}

  @typedoc "Result of a successful participant removal (membership-only or worker reap)."
  @type removal :: %{
          status: :removed,
          torn_down: :membership_only | :worker,
          deleted_rules: non_neg_integer(),
          repointed_rules: non_neg_integer()
        }

  @doc """
  Remove `participant_uri` from `session_uri` on behalf of `ctx.caller`,
  authorized by `ctx.caps` at the dispatch chokepoint.

  The owner holds the create-time `:remove_participant` cap; an admin holds the
  wildcard; a self-leaver (`caller == participant`) gets an inline self-scoped
  cap added here. The handler then identity-gates owner / self / admin.

  Returns the `removal/0` map, `:already_removed`, or `{:error, reason}`
  (`:unauthorized`, `{:worker_teardown_failed, _}`, …).
  """
  @spec remove_participant(URI.t(), URI.t(), ctx()) ::
          {:ok, removal() | :already_removed} | {:error, term()}
  def remove_participant(
        %URI{} = session_uri,
        %URI{} = participant_uri,
        %{caller: %URI{} = caller} = ctx
      ) do
    caps = ctx |> Map.get(:caps, []) |> to_cap_set()

    # Self-leave (§3.3): a participant may always remove ITSELF — add the inline
    # self-scoped cap so the dispatch clears the chokepoint even when the caller
    # holds only the participation tier. (No-op for owner/admin callers, whose
    # passed caps already authorize.)
    result =
      with {:ok, caps} <- maybe_add_self_remove_cap(caps, session_uri, participant_uri, caller) do
        Invocation.dispatch(%Invocation{
          target: Ezagent.URI.with_action(session_uri, :session, :remove_participant),
          mode: :call,
          args: %{participant: participant_uri},
          ctx: %{caller: caller, caps: caps, reply: {:caller_inbox, self()}},
          origin: :trusted_internal
        })
      end

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

  defp to_cap_set(%MapSet{} = caps), do: caps
  defp to_cap_set(caps) when is_list(caps), do: MapSet.new(caps)
  defp to_cap_set(_), do: MapSet.new()

  defp maybe_add_self_remove_cap(caps, session_uri, participant_uri, caller) do
    if caller == participant_uri do
      requested = Membership.self_remove_participant_cap(session_uri, caller)

      case Ezagent.Cap.issue(
             {:admin, Ezagent.Entity.User.admin_uri()},
             caller,
             requested
           ) do
        {:ok, artifact} -> {:ok, MapSet.put(caps, artifact)}
        {:error, _reason} = error -> error
      end
    else
      {:ok, caps}
    end
  end
end
