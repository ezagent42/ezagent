defmodule Mix.Tasks.Ezagent.Session.RemoveParticipant do
  @shortdoc "Remove a participant (user / invited agent) from a session — same path as the operator UI"
  @moduledoc """
  Remove a participant from a session via
  `Ezagent.Session.Participants.remove_participant/3` — the SAME function the
  world UI conversation surface calls (F7 PR-A). CLI and UI share one dispatch
  path; both dispatch the isomorphic `session.remove_participant` action under
  the caller's real caps (CapBAC at the chokepoint).

  This closes the §5.1 gap: before PR-A there was NO operator/CLI path to remove
  a user or an invited (non-orchestrator-spawned) participant from a session.

  ## Usage

      mix ezagent.session.remove_participant <session_uri> <participant_uri> [--as <caller_uri>]

  - `<session_uri>` — `session://<workspace>/<template>/<name>`.
  - `<participant_uri>` — the `entity://…/user/…` or `entity://…/agent/…` URI to remove.
  - `--as <caller_uri>` — the acting entity (defaults to the bootstrap admin).
    The session OWNER (or the participant itself, for self-leave) is authorized;
    a non-owner non-participant caller is denied.

  Isomorphic over participant type (F7 PR-A + PR-B): removing a USER or an
  INVITED (non-spawned) agent is membership-only; removing a worker the session
  SPAWNED reaps it (config-dir GC + termination + lineage forget) under the
  owner's teardown cap. Exits non-zero on error.
  """
  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional, _} = OptionParser.parse(args, strict: [as: :string])

    case positional do
      [session_uri_str, participant_uri_str | _]
      when is_binary(session_uri_str) and session_uri_str != "" and
             is_binary(participant_uri_str) and participant_uri_str != "" ->
        session_uri = parse_uri!(session_uri_str, "session")
        participant_uri = parse_uri!(participant_uri_str, "participant")
        caller_uri = caller_uri(opts)

        case Ezagent.Session.Participants.remove_participant(
               session_uri,
               participant_uri,
               operator_ctx(caller_uri, session_uri)
             ) do
          {:ok, :already_removed} ->
            Mix.shell().info(
              "• #{URI.to_string(participant_uri)} was not a member of #{URI.to_string(session_uri)} (no-op)"
            )

          {:ok, %{status: :removed} = r} ->
            Mix.shell().info(
              "✓ removed #{URI.to_string(participant_uri)} from #{URI.to_string(session_uri)} " <>
                "(torn_down=#{r.torn_down}, deleted_rules=#{r.deleted_rules}, " <>
                "repointed_rules=#{r.repointed_rules})"
            )

          {:error, reason} ->
            Mix.raise("remove_participant failed: #{inspect(reason)}")
        end

      _ ->
        Mix.raise("""
        Missing arguments.

        Usage:
          mix ezagent.session.remove_participant <session_uri> <participant_uri> [--as <caller_uri>]
        """)
    end
  end

  defp caller_uri(opts) do
    case Keyword.get(opts, :as) do
      nil -> Ezagent.Entity.User.admin_uri()
      s -> parse_uri!(s, "caller")
    end
  end

  # Operator ctx (in-VM operator trust §10.5; same pattern as
  # `mix ezagent.agent.create`'s `operator_admin_ctx`): an INLINE
  # `cap(:session, Session, :remove_participant, <session>)` granted_by the
  # caller, so the dispatch clears the chokepoint. The real authorization is the
  # handler's authority gate (owner / self-leave / genesis-wildcard caps) keyed on `caller` — a
  # `--as <stranger>` clears the chokepoint via this inline cap but is then
  # DENIED `:unauthorized` by the handler. Resolving the caller's persisted caps
  # here (a list-caps read) would trip cap_check_only_at_chokepoint p6.
  defp operator_ctx(%URI{} = caller_uri, %URI{} = session_uri) do
    cap = %Ezagent.Capability{
      Ezagent.Capability.cap(
        :session,
        Ezagent.ActionSet.Session,
        :remove_participant,
        Ezagent.URI.instance(session_uri),
        Ezagent.Capability.workspace_of(session_uri)
      )
      | granted_by: caller_uri,
        granted_at: DateTime.utc_now()
    }

    %{caller: caller_uri, caps: [cap]}
  end

  defp parse_uri!(s, label) do
    case Ezagent.URI.parse(String.trim(s)) do
      {:ok, %URI{} = uri} -> uri
      _ -> Mix.raise("bad #{label} URI: #{inspect(s)}")
    end
  end
end
