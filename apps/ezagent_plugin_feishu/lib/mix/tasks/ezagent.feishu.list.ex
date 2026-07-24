defmodule Mix.Tasks.Ezagent.Feishu.List do
  @moduledoc """
  > **Handoff B1 permission-avoidance pivot (2026-07-24).**
  > This task now only validates arguments, prints the deprecation notice
  > and canonical replacement command, and exits. No dispatch, no auth,
  > no mutation — no listing.
  >
  >     mix ezagent.feishu.list --workspace <name>
  >
  > `--workspace` is REQUIRED.
  >
  > **Canonical replacement (authenticated, audit-trailed):**
  >
  >     mix ezagent workspace list_feishu_bindings --workspace <name>
  """

  use Mix.Task

  @shortdoc "DEPRECATED — see `mix ezagent workspace list_feishu_bindings`"

  @impl Mix.Task
  def run(argv) do
    {opts, _positional, _} = OptionParser.parse(argv, switches: [workspace: :string])

    workspace_name = opts[:workspace]

    if is_nil(workspace_name) or workspace_name == "" do
      Mix.raise("""
      --workspace is required. The legacy list task performs NO operation.
      Use the canonical authenticated form:

          mix ezagent workspace list_feishu_bindings --workspace <name>
      """)
    end

    IO.puts("""
    ⚠  mix ezagent.feishu.list is DEPRECATED and performs NO operation.
       Canonical form: mix ezagent workspace list_feishu_bindings \\
         --workspace #{workspace_name}
    """)
  end
end
