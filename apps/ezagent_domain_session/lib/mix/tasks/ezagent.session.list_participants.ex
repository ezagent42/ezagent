defmodule Mix.Tasks.Ezagent.Session.ListParticipants do
  @shortdoc "List a session's current participants (reads the live members slice)"
  @moduledoc """
  List a session's current participant URIs via
  `Ezagent.Session.Participants.list_participants/1` (F7 PR-A).

  Reads the live persisted members slice — the SAME slice the world UI members
  panel renders — so it is the cross-op convergence proof: a UI remove is
  reflected in a subsequent CLI `list`, and a CLI
  `mix ezagent.session.remove_participant` live-updates an open UI (via the
  `{:member_left}` broadcast).

  ## Usage

      mix ezagent.session.list_participants <session_uri>
  """
  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      [session_uri_str | _] when is_binary(session_uri_str) and session_uri_str != "" ->
        session_uri =
          case Ezagent.URI.parse(String.trim(session_uri_str)) do
            {:ok, %URI{} = uri} -> uri
            _ -> Mix.raise("bad session URI: #{inspect(session_uri_str)}")
          end

        members = Ezagent.Session.Participants.list_participants(session_uri)

        Mix.shell().info("participants of #{URI.to_string(session_uri)} (#{length(members)}):")

        Enum.each(members, fn uri -> Mix.shell().info("  - #{URI.to_string(uri)}") end)

      _ ->
        Mix.raise("""
        Missing arguments.

        Usage:
          mix ezagent.session.list_participants <session_uri>
        """)
    end
  end
end
