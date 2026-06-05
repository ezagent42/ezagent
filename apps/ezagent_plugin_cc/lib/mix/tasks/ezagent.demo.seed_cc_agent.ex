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

  @agent_uri_str "entity://agent/system/cc_demo"
  @session_uri_str "session://default/system/main"

  @impl Mix.Task
  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:ezagent_core)
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_instance_message)
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_cc)

    agent_uri = Ezagent.URI.new!(@agent_uri_str)
    session_uri = Ezagent.URI.new!(@session_uri_str)

    with :ok <- spawn_agent_if_absent(agent_uri),
         :ok <- ensure_session_alive(session_uri),
         :ok <- join_agent_to_session(agent_uri, session_uri) do
      Mix.shell().info("""

      ✓ cc demo agent seeded.

        agent:   #{@agent_uri_str}
        session: #{@session_uri_str}

      The cc_demo agent now appears in session://default/system/main members. Open the
      web UI and visit /sessions to interact.
      """)
    else
      {:error, {:session_missing, _uri}} ->
        Mix.shell().info("""

        session://default/system/main has not been created yet.

        Visit `/` in the web UI and complete the first-login wizard to
        create the default session, then re-run `mix ezagent.demo.seed_cc_agent`.
        """)

      {:error, reason} ->
        Mix.raise("seed failed: #{inspect(reason)}")
    end
  end

  defp spawn_agent_if_absent(%URI{} = agent_uri) do
    case Ezagent.KindRegistry.lookup(agent_uri) do
      {:ok, _pid} ->
        Mix.shell().info("  agent already alive: #{URI.to_string(agent_uri)}")
        :ok

      :error ->
        case Ezagent.SpawnRegistry.spawn(agent_uri) do
          {:ok, _pid} ->
            Mix.shell().info("  spawned: #{URI.to_string(agent_uri)}")
            :ok

          {:error, {:already_started, _pid}} ->
            :ok

          {:error, reason} ->
            {:error, {:spawn_failed, reason}}
        end
    end
  end

  defp ensure_session_alive(%URI{} = session_uri) do
    case Ezagent.KindRegistry.lookup(session_uri) do
      {:ok, _pid} ->
        :ok

      :error ->
        # Try a rehydrate-on-reference spawn — snapshot may exist from
        # the previous static-child boot. If still missing, surface the
        # error so the caller prints the friendly wizard hint.
        case Ezagent.SpawnRegistry.spawn(session_uri) do
          {:ok, _pid} ->
            # Re-bind to workspace structurally derived from session URI —
            # same invariant as the wizard's create path (SPEC #324).
            :ok =
              Ezagent.WorkspaceRegistry.bind(
                session_uri,
                Ezagent.Capability.workspace_of(session_uri)
              )

            :ok

          {:error, _} ->
            {:error, {:session_missing, URI.to_string(session_uri)}}
        end
    end
  end

  defp join_agent_to_session(%URI{} = agent_uri, %URI{} = session_uri) do
    target = Ezagent.URI.with_action(session_uri, :chat, :join)

    # SPEC caps-cleanup-v1 §4.4 — operator demo mix task runs under
    # `system://mix-task` (closed Catalog; operator already has shell
    # access, principal exists for audit traceability).
    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: target,
      mode: :cast,
      args: %{member: agent_uri},
      ctx: %{
        caller: Ezagent.SystemPrincipal.uri("mix-task"),
        caps: Ezagent.SystemPrincipal.caps("system://mix-task"),
        reply: :ignore
      }
    })

    :ok
  end
end
