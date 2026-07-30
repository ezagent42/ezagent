defmodule Mix.Tasks.Ezagent.Feishu.Bind do
  @moduledoc """
  > **Handoff B1 permission-avoidance pivot (2026-07-24).**
  > This task now only normalises positional arguments, prints the
  > deprecation notice and canonical replacement command, and exits.
  > No dispatch, no auth, no mutation — the actual bind must go through
  > the authenticated canonical path.
  >
  >     mix ezagent.feishu.bind ou_xxx entity://team-alpha/user/alice
  >
  > **Canonical replacement (authenticated, audit-trailed):**
  >
  >     mix ezagent workspace bind --workspace <name> --open-id <oid> --user-uri <uri>
  """

  use Mix.Task

  @shortdoc "DEPRECATED — see `mix ezagent workspace bind`"

  @impl Mix.Task
  def run(argv) do
    {opts, positional, _} = OptionParser.parse(argv, switches: [admin: :string])

    if opts[:admin] do
      Mix.raise("--admin is no longer accepted. Use the canonical form.")
    end

    {open_id, user_uri_str} =
      case positional do
        [oid, uri] ->
          {oid, uri}

        _ ->
          Mix.raise("""
          usage: mix ezagent.feishu.bind <open_id> <user_uri>

          This task is DEPRECATED and performs NO mutation.
          Prefer the canonical authenticated form:

              mix ezagent workspace bind --workspace <name> --open-id <oid> --user-uri <uri>
          """)
      end

    ws_name =
      case safe_parse_uri(user_uri_str) do
        {:ok, %URI{scheme: "entity"} = user_uri} ->
          Ezagent.URI.workspace_name!(Ezagent.URI.entity_workspace_uri(user_uri))

        {:ok, _} ->
          Mix.raise("user_uri must be a user entity URI")

        {:error, _} ->
          Mix.raise("invalid user URI: #{inspect(user_uri_str)}")
      end

    IO.puts("""
    ⚠  mix ezagent.feishu.bind is DEPRECATED and performs NO mutation.
       Canonical form: mix ezagent workspace bind --workspace #{ws_name} \\
         --open-id #{open_id} --user-uri #{user_uri_str}
    """)
  end

  defp safe_parse_uri(s) do
    {:ok, Ezagent.URI.new!(s)}
  rescue
    ArgumentError -> {:error, :invalid_uri}
  end
end
