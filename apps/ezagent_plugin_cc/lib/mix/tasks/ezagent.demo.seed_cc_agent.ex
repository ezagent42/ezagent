defmodule Mix.Tasks.Ezagent.Demo.SeedCcAgent do
  @shortdoc "Seed a demo cc agent into session://default/system/main"
  @moduledoc """
  > **CLI/GUI parity audit 2026-05-24 — Category A (demo seeder).**
  > Intentionally NOT a normal operator op. Demo-data seed used to
  > populate `session://default/system/main` with a sample cc agent.
  > The `chat.join` step DOES dispatch (with admin caps); the spawn
  > step is a direct `SpawnRegistry.spawn` since there is no live
  > Kind to invoke on yet. Stays as `mix ezagent.*`; do NOT migrate
  > to `mix ezagent`. See
  > `docs/notes/2026-05-24-cli-gui-parity-audit.md` Section 1 (this
  > task is not in the audit matrix — it's a demo-fixtures helper).

  Operator-friendly seed task — spawns `entity://agent/team-alpha/cc_demo` and
  joins it to `session://default/system/main`. Idempotent.

  Allen 2026-05-20: "session://default/system/main 中帮我加入 cc agent demo".

  This task replaces the implicit "you have a cc agent in main because
  Phase 1 created it for you" boot-time behavior. With Phase 8c PR-J the
  session://default/system/main hardcoded boot child is removed (wizard creates it on
  first login); demo data lives outside the boot path so production
  deployments don't get injected with demo agents on every cold start.

  ## Usage

      mix ezagent.demo.seed_cc_agent

  ## What it does

  1. Ensures `entity://agent/team-alpha/cc_demo` is spawned in KindRegistry. If
     already alive, no-op (idempotent).
  2. Dispatches `chat.join` to `session://default/system/main` with the cc_demo agent
     as the member to add. Session must exist (created via the first-
     login wizard at `/`); if not, the task prints a friendly note + exit.
  3. Prints a short confirmation summary.

  ## Why not auto-seed at boot

  See `EzagentDomainInstanceMessage.Application` moduledoc. Auto-injecting demo
  agents into every boot would pollute production deployments with
  fixture data and make the workspace feel "started by someone else"
  to the first real user. Seed-on-demand respects the deployment as
  the operator configured it.

  ## Re-running

  Safe: spawn + join are both idempotent (KindRegistry rejects
  already-started; chat.join updates members map without duplicating).
  """
  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:ezagent_core)
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_session)
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_cc)

    agent_uri = agent_uri()
    session_uri = session_uri()

    with :ok <- spawn_agent_if_absent(agent_uri),
         :ok <- ensure_session_alive(session_uri),
         :ok <- join_agent_to_session(agent_uri, session_uri) do
      Mix.shell().info("""

      ✓ cc demo agent seeded.

        agent:   #{URI.to_string(agent_uri)}
        session: #{URI.to_string(session_uri)}

      The cc_demo agent now appears in the default session members. Open the
      web UI and visit /sessions to interact.
      """)
    else
      {:error, {:session_missing, _uri}} ->
        Mix.shell().info("""

        The default session has not been created yet.

        Visit `/` in the web UI and complete the first-login wizard to
        create the default session, then re-run `mix ezagent.demo.seed_cc_agent`.
        """)

      {:error, reason} ->
        Mix.raise("seed failed: #{inspect(reason)}")
    end
  end

  defp spawn_agent_if_absent(%URI{} = agent_uri) do
    case Ezagent.LocalRuntime.ensure_started_detailed(agent_uri) do
      {:ok, :already_started, _pid} ->
        Mix.shell().info("  agent already alive: #{URI.to_string(agent_uri)}")
        :ok

      {:ok, :started, _pid} ->
        Mix.shell().info("  spawned: #{URI.to_string(agent_uri)}")
        :ok

      {:error, reason} ->
        {:error, {:spawn_failed, reason}}
    end
  end

  defp ensure_session_alive(%URI{} = session_uri) do
    # Try a rehydrate-on-reference ensure — snapshot may exist from the
    # previous static-child boot. If still missing, surface the error so the
    # caller prints the friendly wizard hint.
    case Ezagent.LocalRuntime.ensure_started_detailed(session_uri) do
      {:ok, :already_started, _pid} ->
        :ok

      {:ok, :started, _pid} ->
        # Re-bind to workspace structurally derived from session URI —
        # same invariant as the wizard's create path (SPEC #324). Only on a
        # FRESH spawn (an already-alive session is already bound). Return the
        # owner-gated result directly: :ok on the owner path, {:error, violation}
        # off-owner (fail-closed — the `with` caller short-circuits, no crash).
        Ezagent.OwnerGatedWorkspace.bind(
          session_uri,
          Ezagent.Capability.workspace_of(session_uri)
        )

      {:error, _} ->
        {:error, {:session_missing, URI.to_string(session_uri)}}
    end
  end

  defp join_agent_to_session(%URI{} = agent_uri, %URI{} = session_uri) do
    target = Ezagent.URI.with_action(session_uri, :session, :join)

    admin_uri = Ezagent.Entity.User.admin_uri()

    # System-principal elimination (#154, 2026-06-19) — operator demo task runs
    # under the real genesis admin entity (`User.admin_uri/0`), NOT the
    # eliminated `system://mix-task` ambient wildcard (shell access = admin
    # authority, in-VM trust §10.5). This is a NON-grant `session.join` dispatch;
    # the INLINE `cap(:session, Session, :join)` scoped to the target session is
    # the step-5.5 authorizer. `granted_by` = `admin_uri` (a real entity per
    # #154, provenance only on an inline authorizer never routed through
    # `Ezagent.Identity.Grant`).
    {:ok, signed_cap} =
      Ezagent.Cap.issue_for_action({:admin, admin_uri}, admin_uri, target)

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: target,
      mode: :cast,
      args: %{member: agent_uri},
      ctx: %{
        caller: admin_uri,
        authenticated_principal: admin_uri,
        caps: [signed_cap],
        reply: :ignore
      },
      origin: :trusted_internal
    })

    :ok
  end

  defp agent_uri, do: Ezagent.URI.agent(:system, :cc_demo)
  defp session_uri, do: Ezagent.URI.session(:system, :default, :main)
end
