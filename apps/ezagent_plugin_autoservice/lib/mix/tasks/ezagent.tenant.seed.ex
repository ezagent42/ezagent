defmodule Mix.Tasks.Ezagent.Tenant.Seed do
  @shortdoc "Seed a tenant + customer (+ optional operator/admin) for the AutoService CS vertical"
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
  3. Optionally provisions an operator user (`--operator <name>`, default: `bob`):
     - Creates/ensures the operator User entity with password = operator name.
     - Grants operator the `Roles.bundle(:operator, ws)` caps: session:join +
       turn:claim/settle + cs_orchestrator:operator_claim/settle.
  4. Optionally provisions a tenant-admin user (`--admin <name>`, default: `carol`):
     - Creates/ensures the tenant-admin User entity with password = admin name.
     - Grants admin the `Roles.bundle(:tenant_admin, ws)` caps: workspace manage +
       content write + user create.
  5. Prints a summary with all URIs and the login hint.

  ## Usage

      mix ecto.create && mix ecto.migrate    # first run only
      mix ezagent.tenant.seed
      mix ezagent.tenant.seed --tenant cinnox --customer alice --operator bob --admin carol

  ## Options

  - `--tenant` — workspace / tenant name (default: `cinnox`)
  - `--customer` — customer short name (default: `alice`)
  - `--operator` — operator short name (default: `bob`); pass empty string to skip
  - `--admin` — tenant-admin short name (default: `carol`); pass empty string to skip
  - `--no-agents` — skip real cc/curl `create_agent` calls; bring agents up as
    plain entity stubs (structural seed only, no live AI reply).

  After seeding, with the server running (`mix phx.server`):
  - Customer login: `/login` as `<customer>` / `<customer>`, open `/autoservice`.
  - Operator login: `/login` as `<operator>` / `<operator>`, open `/autoservice/operator`.
  """
  use Mix.Task

  alias EzagentPluginAutoservice.Assembly

  @default_tenant "cinnox"
  @default_customer "alice"
  @default_operator "bob"
  @default_admin "carol"

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _} =
      OptionParser.parse(argv,
        strict: [
          tenant: :string,
          customer: :string,
          operator: :string,
          admin: :string,
          no_agents: :boolean
        ]
      )

    tid = Keyword.get(opts, :tenant, @default_tenant)
    customer = Keyword.get(opts, :customer, @default_customer)
    operator = Keyword.get(opts, :operator, @default_operator)
    admin = Keyword.get(opts, :admin, @default_admin)
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
        # Provision operator user if name is non-empty.
        operator_uri =
          if operator != "" do
            Mix.shell().info("Provisioning operator=#{operator} …")

            case Assembly.ensure_operator(tid, operator) do
              {:ok, op_uri} ->
                Mix.shell().info("  operator URI: #{URI.to_string(op_uri)}")
                op_uri

              {:error, reason} ->
                Mix.shell().error("  operator provision failed: #{inspect(reason)} (continuing)")
                nil
            end
          else
            nil
          end

        # Provision tenant-admin user if name is non-empty.
        tenant_admin_uri =
          if admin != "" do
            Mix.shell().info("Provisioning tenant-admin=#{admin} …")

            case Assembly.ensure_admin(tid, admin) do
              {:ok, a_uri} ->
                Mix.shell().info("  tenant-admin URI: #{URI.to_string(a_uri)}")
                a_uri

              {:error, reason} ->
                Mix.shell().error(
                  "  tenant-admin provision failed: #{inspect(reason)} (continuing)"
                )

                nil
            end
          else
            nil
          end

        print_summary(
          result,
          customer,
          operator,
          operator_uri,
          admin,
          tenant_admin_uri,
          create_agents?
        )

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
         operator,
         operator_uri,
         admin,
         tenant_admin_uri,
         create_agents?
       ) do
    agent_note =
      if create_agents? do
        "real cc + curl agents"
      else
        "stub entities (--no-agents; no live AI reply)"
      end

    operator_line =
      if operator_uri do
        "  operator     #{URI.to_string(operator_uri)}"
      else
        "  operator     (not seeded — pass --operator <name> to seed)"
      end

    admin_line =
      if tenant_admin_uri do
        "  tenant-admin #{URI.to_string(tenant_admin_uri)}"
      else
        "  tenant-admin (not seeded — pass --admin <name> to seed)"
      end

    operator_hint =
      if operator_uri do
        "\nOperator login: /login as `#{operator}` / password `#{operator}`,\nthen open /autoservice/operator."
      else
        ""
      end

    admin_hint =
      if tenant_admin_uri do
        "\nTenant-admin login: /login as `#{admin}` / password `#{admin}`."
      else
        ""
      end

    Mix.shell().info("""

    AutoService CS seeded.

      session      #{URI.to_string(session_uri)}
      customer     #{URI.to_string(customer_uri)}
      orchestrator #{URI.to_string(orch_uri)}
      fast agent   #{URI.to_string(fast_uri)}
      slow agent   #{URI.to_string(slow_uri)}
    #{operator_line}
    #{admin_line}
      agents:      #{agent_note}

    Customer login: /login as `#{customer}` / password `#{customer}`,
    then open /autoservice.#{operator_hint}#{admin_hint}
    """)
  end
end
