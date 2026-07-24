defmodule Mix.Tasks.Ezagent.Feishu.Unbind do
  @moduledoc """
  > **Handoff B1 permission-avoidance pivot (2026-07-24).**
  > This task now only validates arguments, prints the deprecation notice
  > and canonical replacement command, and exits. No dispatch, no auth,
  > no mutation.
  >
  >     mix ezagent.feishu.unbind ou_xxx --workspace <name>
  >
  > `--workspace` is REQUIRED.
  >
  > **Canonical replacement (authenticated, audit-trailed):**
  >
  >     mix ezagent workspace unbind --workspace <name> --open-id <oid>
  """

  use Mix.Task

  @shortdoc "DEPRECATED — see `mix ezagent workspace unbind`"

  @impl Mix.Task
  def run(argv) do
    {opts, positional, _} = OptionParser.parse(argv, switches: [workspace: :string])

    workspace_name = opts[:workspace]

    if is_nil(workspace_name) or workspace_name == "" do
      Mix.raise("""
      --workspace is required. The legacy unbind task performs NO mutation.
      Use the canonical authenticated form:

          mix ezagent workspace unbind --workspace <name> --open-id <oid>
      """)
    end

    open_id =
      case positional do
        [oid | _] when is_binary(oid) and oid != "" ->
          oid

        _ ->
          Mix.raise("""
          usage: mix ezagent.feishu.unbind <open_id> --workspace <name>

          This task is DEPRECATED and performs NO mutation.
          Prefer the canonical authenticated form:

              mix ezagent workspace unbind --workspace <name> --open-id <oid>
          """)
      end

    IO.puts("""
    ⚠  mix ezagent.feishu.unbind is DEPRECATED and performs NO mutation.
       Canonical form: mix ezagent workspace unbind --workspace #{workspace_name} \\
         --open-id #{open_id}
    """)
  end
end
