defmodule Mix.Tasks.Ezagent.Tenant.Seed do
  @shortdoc "Seed a tenant + customer for the AutoService CS vertical"
  @moduledoc """
  Seeds the AutoService CS vertical end-to-end for a single tenant + customer:

  1. Ensures the admin user is alive.
  2. Calls `EzagentPluginAutoservice.Assembly.provision_session/3`:
     - CR publisher init (content release v1).
     - workspace + customer user (password = customer name, enables web login).
     - SocialwareSession.
     - Slow cc agent (content-fed CLAUDE.md + optional KB MCP config).
     - Fast curl agent (content-fed system_prompt + provider config).
     - CS Orchestrator.
     - Routing rule (in_session → orchestrator).
  3. Prints a summary with all URIs and the login hint.

  ## Usage

      mix ecto.create && mix ecto.migrate    # first run only
      mix ezagent.tenant.seed
      mix ezagent.tenant.seed --tenant cinnox --customer alice

  ## Options

  - `--tenant` — workspace / tenant name (default: `cinnox`)
  - `--customer` — customer short name (default: `alice`)
  - `--no-agents` — skip real cc/curl `create_agent` calls; bring agents up as
    plain entity stubs (structural seed only, no live AI reply).

  After seeding, with the server running (`mix phx.server`), log in at
  `/login` as `<customer>` / `<customer>` and open `/autoservice`.
  """
  use Mix.Task

  alias EzagentPluginAutoservice.Assembly

  @default_tenant "cinnox"
  @default_customer "alice"

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _} =
      OptionParser.parse(argv,
        strict: [tenant: :string, customer: :string, no_agents: :boolean]
      )

    tid = Keyword.get(opts, :tenant, @default_tenant)
    customer = Keyword.get(opts, :customer, @default_customer)
    create_agents? = not Keyword.get(opts, :no_agents, false)

    {:ok, _} = Application.ensure_all_started(:ezagent_core)
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_identity)
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_workspace)
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_instance_message)
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_socialware)
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_cc)
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_curl_agent)
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_content)
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_cr)
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_autoservice)

    ctx = mix_task_ctx()

    Mix.shell().info(
      "Seeding AutoService CS for tenant=#{tid} customer=#{customer} " <>
        "(agents: #{if create_agents?, do: "real", else: "stubs"}) …"
    )

    case Assembly.provision_session(tid, customer, ctx, create_agents: create_agents?) do
      {:ok, result} ->
        print_summary(result, customer, create_agents?)

      {:error, reason} ->
        Mix.raise("provision_session failed for #{tid}/#{customer}: #{inspect(reason)}")
    end
  end

  # --- helpers ------------------------------------------------------------

  # Caller must be a REAL entity (not a system principal): create_agent's
  # authorize-at-create grants the CREATOR a Manage cap by dispatching
  # identity.grant_cap to the creator's own Kind — a system:// principal
  # has no Kind and fails with {:creator_manage_cap_grant_failed, :no_such_actor}
  # (found live, Stage-1 seed run 3). Use the bootstrap admin user.
  defp mix_task_ctx do
    %{
      caller: Ezagent.Entity.User.admin_uri(),
      caps: Ezagent.SystemPrincipal.caps("system://mix-task")
    }
  end

  defp print_summary(
         %{
           session_uri: session_uri,
           customer_uri: customer_uri,
           orchestrator_uri: orch_uri,
           fast_uri: fast_uri,
           slow_uri: slow_uri
         },
         customer,
         create_agents?
       ) do
    agent_note =
      if create_agents? do
        "real cc + curl agents"
      else
        "stub entities (--no-agents; no live AI reply)"
      end

    Mix.shell().info("""

    AutoService CS seeded.

      session      #{URI.to_string(session_uri)}
      customer     #{URI.to_string(customer_uri)}
      orchestrator #{URI.to_string(orch_uri)}
      fast agent   #{URI.to_string(fast_uri)}
      slow agent   #{URI.to_string(slow_uri)}
      agents:      #{agent_note}

    Login at /login as `#{customer}` / password `#{customer}`,
    then open /autoservice.
    """)
  end
end
