defmodule Mix.Tasks.Ezagent.Stress do
  @shortdoc "V1 acceptance stress-test driver (NOT a production tool)"

  @moduledoc """
  > **CLI/GUI parity audit 2026-05-24 — Category A (measurement tool).**
  > Intentionally NOT a dispatched op. Stress-test driver that drives
  > the runtime from outside via a measurement harness. Stays as
  > `mix ezagent.*`; do NOT migrate to `mix ezagent`. See
  > `docs/notes/2026-05-24-cli-gui-parity-audit.md` Section 1
  > (Bootstrap row) + Finding 2 carve-out.

  V1 acceptance stress-test driver — executes the scenarios from
  `docs/superpowers/plans/2026-05-22-v1-stress-test-plan.md`.

  This task is a one-off measurement tool, NOT a permanent load-testing
  framework and NOT part of a normal build / CI run. It exists so the
  V1 acceptance numbers can be re-measured. It does not run unless
  invoked explicitly.

  ## Usage

      mix ezagent.stress --scenario a --out /tmp/stress-a.jsonl
      mix ezagent.stress --scenario b --out /tmp/stress-b.jsonl
      mix ezagent.stress --scenario c --out /tmp/stress-c.jsonl

  Run with a Raspberry-Pi resource profile:

      ELIXIR_ERL_OPTIONS="+S 4:4" mix ezagent.stress --scenario a ...

  ## Options

  * `--scenario` — `a` (agents-per-session), `b` (max sessions),
    `c` (max users). Required.
  * `--ramp` — comma-separated ramp steps. Defaults per scenario.
  * `--hold-ms` — steady-state hold per ramp step (default 8000).
  * `--rate` — messages/sec injected during a hold (scenario A; default 5).
  * `--turn-cap` — auto-reply hop cap. `0` = sink mode, no reply (the only
    mode supported after the echo→py retirement; see the sink-member note below)
    (the default, for pure capacity). `>0` enables bounded auto-reply.
  * `--mem-ceiling-mb` — abort the ramp if RSS exceeds this (default 3500,
    a ~4 GB Pi headroom).
  * `--out` — JSONL results file (one object per ramp step).

  ## Scenarios

  * **A — agents per session.** One session, ramp the member count.
    Inject `--rate` msg/s for `--hold-ms`; measure dispatch latency
    p50/p99, throughput, memory.
  * **B — max sessions.** Ramp concurrent sessions (1 user + 2 sink
    agents each); measure process count, RSS, ETS, spawn throughput.
  * **C — max users.** Ramp concurrent User Kinds; measure process
    count, RSS, ETS.

  ## Loop-amplification safety (plan §7)

  Every injected message carries a `meta` map with `hop` + `turn_cap`
  in its body. `turn_cap: 0` disables auto-reply entirely (sink mode),
  the driver injects a fixed message budget per hold window and never
  loops. (The echo `:receive` auto-reply path — `hop >= turn_cap`
  refusal — was retired with the echo flavor in P2; sink members
  now spawn on the unified `Ezagent.Entity.Agent` Kind. See the
  `@sink_mod` note for the `turn_cap > 0` follow-up.)
  """

  use Mix.Task

  alias Ezagent.{Invocation, Kind, Message, ReadyGate, StressMetrics, WorkspaceRegistry}

  # Entity Kind modules live in higher-tier umbrella apps
  # (`ezagent_domain_session`, `ezagent_domain_identity`, `ezagent_domain_agent`)
  # that depend on `ezagent_core` — `ezagent_core` cannot alias them at
  # compile time without a dependency cycle. They ARE loaded by the time
  # this task runs (`Mix.Task.run("app.start")` boots the whole
  # umbrella), so the task resolves + calls them at runtime via the
  # `session_mod/0` / `user_mod/0` / `echo_mod/0` accessors below.
  @session_mod Module.concat([:Ezagent, :Entity, :Session])
  @user_mod Module.concat([:Ezagent, :Entity, :User])
  # P2 retired the echo flavor + its Kind (echo→py). The stress scenarios used
  # it as a cheap in-BEAM SINK member (default `turn_cap: 0`, no reply). The
  # unified `Ezagent.Entity.Agent` Kind stands in as a member. NOTE/TODO: the
  # auto-reply bounce path (`turn_cap > 0`) was the echo flavor's hop logic — it
  # is NOT reproduced here (Entity.Agent's `:receive` routes to the LLM-backed
  # `Behavior.Agent.Receive`, which is not a trivial echo). For sink scenarios
  # (the default) Entity.Agent is a clean drop-in; a purpose-built trivial sink
  # or a py-agent member is the fast-follow if `turn_cap > 0` throughput is
  # needed. This is a dev-only Mix task — it compiles + sink-runs; it does not
  # gate P2.
  @sink_mod Module.concat([:Ezagent, :Entity, :Agent])

  defp session_mod, do: @session_mod
  # P5-0b: the Session Kind requires an explicit :kind_base behavior set threaded
  # at spawn (chat subset). Resolved at runtime (Session lives in a higher-tier app).
  defp session_behaviors, do: apply(@session_mod, :chat_behaviors, [])
  defp user_mod, do: @user_mod
  defp sink_mod, do: @sink_mod
  defp admin_uri, do: apply(@user_mod, :admin_uri, [])

  # System-principal elimination (#154, 2026-06-19) — the operator stress
  # harness runs under the real genesis admin entity (`admin_uri/0`), NOT the
  # eliminated `system://mix-task` ambient wildcard (shell access = admin
  # authority, in-VM trust §10.5). `admin_caps/0` is called from BOTH the
  # `session.send` traffic injector (`inject_messages/4`) and the `session.join`
  # member binding (`join!/2`), across MANY dynamically-created stress sessions
  # in `workspace://system`. So it carries BOTH per-action `cap(:session,
  # Session, :send | :join)` authorizers with `instance: :any` (the harness
  # creates sessions on the fly — pinning a concrete instance is impractical and
  # the operator IS admin). `granted_by` = `admin_uri` (a real entity per #154,
  # provenance only on inline authorizers never routed through
  # `Ezagent.Identity.Grant`). Returns a list — step 5.5 iterates either a list
  # or a MapSet and picks the matching action.
  defp admin_caps(session_uri) do
    admin = admin_uri()

    Enum.map([:send, :join], fn action ->
      target = Ezagent.URI.with_action(session_uri, :session, action)

      case Ezagent.Cap.issue_for_action({:admin, admin}, admin, target) do
        {:ok, cap} -> cap
        {:error, reason} -> Mix.raise("stress cap issuance failed: #{inspect(reason)}")
      end
    end)
  end

  defp user_default_caps(ws_uri), do: apply(@user_mod, :default_caps, [ws_uri])

  @switches [
    scenario: :string,
    ramp: :string,
    hold_ms: :integer,
    rate: :integer,
    turn_cap: :integer,
    mem_ceiling_mb: :integer,
    out: :string
  ]

  @default_ramps %{
    "a" => [2, 5, 10, 25, 50, 100],
    "b" => [10, 50, 100, 250, 500, 1000],
    "c" => [100, 500, 1000, 2500, 5000, 10_000]
  }

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, switches: @switches)

    scenario = opts[:scenario] || Mix.raise("--scenario a|b|c is required")
    scenario = String.downcase(scenario)

    unless scenario in ["a", "b", "c"] do
      Mix.raise("--scenario must be one of a, b, c")
    end

    # Boot the full runtime (core + domain + plugin apps). We do NOT
    # need the Phoenix endpoint — drive the runtime directly — but
    # ensuring the umbrella's applications start brings up the Repo,
    # PubSub, KindRegistry, ReadyGate, Audit.Writer and the plugin
    # behavior registrations.
    Mix.Task.run("app.start")

    ramp =
      case opts[:ramp] do
        nil -> @default_ramps[scenario]
        s -> s |> String.split(",", trim: true) |> Enum.map(&String.to_integer/1)
      end

    hold_ms = opts[:hold_ms] || 8_000
    rate = opts[:rate] || 5
    turn_cap = opts[:turn_cap] || 0
    mem_ceiling = opts[:mem_ceiling_mb] || 3_500
    out = opts[:out] || "/tmp/ezagent-stress-#{scenario}.jsonl"

    {:ok, _} = StressMetrics.start_link()

    log("=== V1 stress-test scenario #{String.upcase(scenario)} ===")
    log("ramp=#{inspect(ramp)} hold_ms=#{hold_ms} rate=#{rate}/s turn_cap=#{turn_cap}")

    log(
      "schedulers=#{:erlang.system_info(:schedulers_online)}/#{:erlang.system_info(:schedulers)}"
    )

    log("mem ceiling=#{mem_ceiling} MB  process_limit=#{:erlang.system_info(:process_limit)}")
    log("DB: #{db_info()}")

    File.rm(out)

    cfg = %{
      scenario: scenario,
      hold_ms: hold_ms,
      rate: rate,
      turn_cap: turn_cap,
      mem_ceiling: mem_ceiling,
      out: out
    }

    run_ramp(cfg, ramp)

    StressMetrics.stop()
    log("=== done — results: #{out} ===")
  end

  # --- ramp loop ---------------------------------------------------------

  defp run_ramp(cfg, ramp) do
    Enum.reduce_while(ramp, %{prev_count: 0}, fn n, acc ->
      log("")
      log("--- ramp step: N=#{n} ---")

      result = run_step(cfg, n, acc.prev_count)
      append_jsonl(cfg.out, result)
      print_step(result)

      cond do
        result.aborted ->
          log("ABORT — #{result.abort_reason}. Knee at N <= #{n}.")
          {:halt, acc}

        result.system.rss_mb > cfg.mem_ceiling ->
          log("STOP — RSS #{result.system.rss_mb} MB exceeded ceiling #{cfg.mem_ceiling} MB.")
          {:halt, acc}

        true ->
          {:cont, %{prev_count: n}}
      end
    end)
  end

  # --- per-scenario step -------------------------------------------------

  defp run_step(%{scenario: "a"} = cfg, n, _prev) do
    # Scenario A — one session, N agent members. Re-create the session
    # fresh each step so membership is exactly N.
    workspace = "system"
    session_uri = Ezagent.URI.session(workspace, :default, "stress_a_#{n}")

    {spawn_us, :ok} =
      timed(fn ->
        spawn_kind!(session_mod(), session_uri, %{behaviors: session_behaviors()})
        :ok = WorkspaceRegistry.bind(session_uri, Ezagent.URI.workspace(workspace))
        await_ready!(session_uri)

        for i <- 1..n do
          agent_uri = Ezagent.URI.agent(workspace, "sink_a#{n}_#{i}")
          spawn_kind!(sink_mod(), agent_uri)
          await_ready!(agent_uri)
          join!(session_uri, agent_uri)
        end

        :ok
      end)

    StressMetrics.reset()

    # Inject a fixed message budget: rate msg/s across the hold window.
    # `--rate 0` is unpaced burst mode — fire the whole budget as fast
    # as possible (used to find the true DB write knee, since paced
    # injection is `Process.sleep`-floor-bound at ~500/s).
    {budget, interval_ms} =
      if cfg.rate == 0 do
        {max(1, round(cfg.hold_ms / 1000 * 5000)), 0}
      else
        b = max(1, round(cfg.rate * cfg.hold_ms / 1000))
        {b, max(1, div(cfg.hold_ms, b))}
      end

    {inject_us, injected} =
      timed(fn ->
        inject_messages(session_uri, budget, interval_ms, cfg.turn_cap)
      end)

    # `chat.send` is dispatched `:cast` — the driver's inject loop
    # returns the instant the casts are enqueued. The real work happens
    # asynchronously in the Session GenServer (each cast = one
    # MessageStore transaction + N-1 receive dispatches). To measure
    # *sustained* throughput we drain to quiescence: poll the dispatch
    # counter + the Session mailbox until both stop moving, and time
    # the whole inject→drain window.
    {drain_us, peak_mailbox} = drain_to_quiescence(session_uri)
    total_us = inject_us + drain_us

    metrics = StressMetrics.snapshot()
    system = StressMetrics.system_sample()

    base_result(cfg, n, %{
      members: n,
      spawn_ms: round(spawn_us / 1000),
      inject_ms: round(inject_us / 1000),
      drain_ms: round(drain_us / 1000),
      total_ms: round(total_us / 1000),
      peak_session_mailbox: peak_mailbox,
      messages_injected: injected,
      messages_per_sec: throughput(injected, total_us),
      dispatch_per_sec: throughput(metrics.invoke_count, total_us),
      dispatches: metrics.invoke_count,
      dispatch_p50_us: metrics.dispatch_p50_us,
      dispatch_p99_us: metrics.dispatch_p99_us,
      dispatch_max_us: metrics.dispatch_max_us,
      dispatch_errors: metrics.invoke_error_count,
      repo_queries: metrics.repo_query_count,
      repo_queue_p99_us: metrics.repo_queue_p99_us,
      repo_query_p99_us: metrics.repo_query_p99_us,
      persist_writes: metrics.persist_count,
      metrics: metrics,
      system: system
    })
  end

  defp run_step(%{scenario: "b"} = cfg, n, prev) do
    # Scenario B — ramp concurrent sessions. Each new step adds
    # (n - prev) sessions, each with 1 user + 2 sink agents. Sessions
    # accumulate across steps (we measure HOLDING many sessions).
    workspace = "system"
    StressMetrics.reset()

    {spawn_us, :ok} =
      timed(fn ->
        for s <- (prev + 1)..n do
          session_uri = Ezagent.URI.session(workspace, :default, "stress_b_#{s}")
          spawn_kind!(session_mod(), session_uri, %{behaviors: session_behaviors()})
          :ok = WorkspaceRegistry.bind(session_uri, Ezagent.URI.workspace(workspace))
          await_ready!(session_uri)

          user_uri = Ezagent.URI.user(workspace, "u_b#{s}")
          spawn_user!(user_uri, workspace)
          await_ready!(user_uri)
          join!(session_uri, user_uri)

          for a <- 1..2 do
            agent_uri = Ezagent.URI.agent(workspace, "sink_b#{s}_#{a}")
            spawn_kind!(sink_mod(), agent_uri)
            await_ready!(agent_uri)
            join!(session_uri, agent_uri)
          end
        end

        :ok
      end)

    Process.sleep(cfg.hold_ms)

    metrics = StressMetrics.snapshot()
    system = StressMetrics.system_sample()
    added = n - prev
    entities_added = added * 4

    base_result(cfg, n, %{
      sessions_total: n,
      sessions_added: added,
      entities_added: entities_added,
      spawn_ms: round(spawn_us / 1000),
      spawn_per_sec: throughput(entities_added, spawn_us),
      persist_writes: metrics.persist_count,
      metrics: metrics,
      system: system
    })
  end

  defp run_step(%{scenario: "c"} = cfg, n, prev) do
    # Scenario C — ramp concurrent User Kinds. Users accumulate across
    # steps; mostly idle.
    workspace = "system"
    StressMetrics.reset()

    {spawn_us, :ok} =
      timed(fn ->
        for u <- (prev + 1)..n do
          user_uri = Ezagent.URI.user(workspace, "u_c#{u}")
          spawn_user!(user_uri, workspace)
          await_ready!(user_uri)
        end

        :ok
      end)

    Process.sleep(cfg.hold_ms)

    metrics = StressMetrics.snapshot()
    system = StressMetrics.system_sample()
    added = n - prev

    base_result(cfg, n, %{
      users_total: n,
      users_added: added,
      spawn_ms: round(spawn_us / 1000),
      spawn_per_sec: throughput(added, spawn_us),
      persist_writes: metrics.persist_count,
      metrics: metrics,
      system: system
    })
  end

  defp base_result(cfg, n, fields) do
    Map.merge(
      %{
        scenario: cfg.scenario,
        n: n,
        at: DateTime.utc_now() |> DateTime.to_iso8601(),
        aborted: false,
        abort_reason: nil
      },
      fields
    )
  end

  # --- traffic injection -------------------------------------------------

  defp inject_messages(session_uri, budget, interval_ms, turn_cap) do
    admin = admin_uri()
    target = Ezagent.URI.with_action(session_uri, :session, :send)
    caps = admin_caps(session_uri)

    Enum.reduce(1..budget, 0, fn i, count ->
      body = %{
        text: "stress msg #{i}",
        attachments: [],
        meta: %{"hop" => 0, "turn_cap" => turn_cap}
      }

      msg = Message.new(admin, body)

      Invocation.dispatch(%Invocation{
        target: target,
        mode: :cast,
        args: %{message: msg},
        ctx: %{
          caller: admin,
          authenticated_principal: admin,
          caps: caps,
          reply: :ignore
        },
        origin: :trusted_internal
      })

      if i < budget and interval_ms > 0, do: Process.sleep(interval_ms)
      count + 1
    end)
  end

  # Poll until the dispatch counter AND the Session GenServer mailbox
  # both stop moving for two consecutive samples — i.e. the burst has
  # fully drained. Returns `{drain_us, peak_mailbox_len}`. Caps out at
  # ~60 s so a genuine runaway is reported rather than hanging.
  defp drain_to_quiescence(session_uri) do
    t0 = System.monotonic_time(:microsecond)
    drain_loop(session_uri, t0, -1, 0, 0)
  end

  defp drain_loop(session_uri, t0, last_count, stable, peak) do
    Process.sleep(100)
    elapsed = System.monotonic_time(:microsecond) - t0
    count = StressMetrics.snapshot().invoke_count
    mailbox = session_mailbox_len(session_uri)
    peak2 = max(peak, mailbox)

    cond do
      elapsed > 60_000_000 ->
        {elapsed, peak2}

      count == last_count and mailbox == 0 and stable >= 2 ->
        {elapsed, peak2}

      count == last_count and mailbox == 0 ->
        drain_loop(session_uri, t0, count, stable + 1, peak2)

      true ->
        drain_loop(session_uri, t0, count, 0, peak2)
    end
  end

  defp session_mailbox_len(session_uri) do
    case Ezagent.KindRegistry.lookup(session_uri) do
      {:ok, pid} ->
        case Process.info(pid, :message_queue_len) do
          {:message_queue_len, n} -> n
          nil -> 0
        end

      :error ->
        0
    end
  end

  # --- spawn helpers -----------------------------------------------------

  defp spawn_kind!(kind_module, uri, extra \\ %{}) do
    # derivation-edge: test-scenario stress fixture, never a product principal
    case Kind.spawn(kind_module, Map.merge(%{uri: uri}, extra)) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, {:already_registered, _}} -> :ok
      {:error, reason} -> Mix.raise("spawn #{inspect(kind_module)} failed: #{inspect(reason)}")
    end
  end

  defp spawn_user!(uri, workspace) do
    caps = user_default_caps(Ezagent.URI.workspace(workspace))

    # derivation-edge: test-scenario stress fixture, never a product principal
    case Kind.spawn(user_mod(), %{uri: uri, initial_caps: MapSet.new(caps)}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, {:already_registered, _}} -> :ok
      {:error, reason} -> Mix.raise("spawn User failed: #{inspect(reason)}")
    end
  end

  # Poll ReadyGate until the Kind announces ready. The Kind.Server
  # lifecycle is register → subscribe → announce_ready; dispatch to a
  # not-ready :cast target buffers, but :call (chat.join) fails fast,
  # so the driver waits for :ready before joining.
  defp await_ready!(uri, tries \\ 200)

  defp await_ready!(uri, 0) do
    Mix.raise("timeout waiting for #{URI.to_string(uri)} to become ready")
  end

  defp await_ready!(uri, tries) do
    case ReadyGate.status(uri) do
      :ready ->
        :ok

      _ ->
        Process.sleep(10)
        await_ready!(uri, tries - 1)
    end
  end

  defp join!(session_uri, member_uri) do
    target = Ezagent.URI.with_action(session_uri, :session, :join)

    result =
      Invocation.dispatch(%Invocation{
        target: target,
        mode: :call,
        args: %{member: member_uri},
        ctx: %{
          caller: admin_uri(),
          authenticated_principal: admin_uri(),
          caps: admin_caps(session_uri),
          reply: {:caller_inbox, self()}
        },
        origin: :trusted_internal
      })

    case result do
      {:ok, _} -> :ok
      :ok -> :ok
      {:error, reason} -> Mix.raise("join failed: #{inspect(reason)}")
    end
  end

  # --- misc --------------------------------------------------------------

  defp timed(fun) do
    t0 = System.monotonic_time(:microsecond)
    result = fun.()
    {System.monotonic_time(:microsecond) - t0, result}
  end

  defp throughput(_count, 0), do: 0.0
  defp throughput(count, us), do: Float.round(count * 1_000_000 / us, 1)

  defp db_info do
    Ezagent.Persistence.DatabaseDiagnostics.summary()
  end

  defp append_jsonl(path, result) do
    line = result |> sanitize() |> Jason.encode!()
    File.write!(path, line <> "\n", [:append])
  end

  # Drop the nested raw structs that Jason can't encode cleanly.
  defp sanitize(result) do
    result
    |> Map.drop([:metrics])
    |> Map.update(:system, %{}, & &1)
  end

  defp print_step(%{scenario: "a"} = r) do
    log(
      "  members=#{r.members} spawn=#{r.spawn_ms}ms " <>
        "msgs=#{r.messages_injected} inject=#{r.inject_ms}ms drain=#{r.drain_ms}ms " <>
        "(#{r.messages_per_sec} msg/s, #{r.dispatch_per_sec} dispatch/s)"
    )

    log(
      "  dispatches=#{r.dispatches} errs=#{r.dispatch_errors} " <>
        "peak_session_mailbox=#{r.peak_session_mailbox}"
    )

    log(
      "  dispatch p50=#{us(r.dispatch_p50_us)} p99=#{us(r.dispatch_p99_us)} " <>
        "max=#{us(r.dispatch_max_us)}  repo_q p99=#{us(r.repo_queue_p99_us)} " <>
        "repo_query p99=#{us(r.repo_query_p99_us)}"
    )

    log(
      "  procs=#{r.system.process_count} rss=#{r.system.rss_mb}MB " <>
        "beam_total=#{r.system.mem_total_mb}MB persist_writes=#{r.persist_writes}"
    )
  end

  defp print_step(%{scenario: s} = r) when s in ["b", "c"] do
    label = if s == "b", do: "sessions=#{r.sessions_total}", else: "users=#{r.users_total}"

    log(
      "  #{label} spawn=#{r.spawn_ms}ms (#{r.spawn_per_sec} entities/s) " <>
        "persist_writes=#{r.persist_writes}"
    )

    log(
      "  procs=#{r.system.process_count} rss=#{r.system.rss_mb}MB " <>
        "beam_total=#{r.system.mem_total_mb}MB ets=#{r.system.mem_ets_mb}MB " <>
        "kind_registry=#{r.system.kind_registry_size}"
    )
  end

  defp us(n) when is_integer(n), do: "#{Float.round(n / 1000, 2)}ms"
  defp us(_), do: "?"

  defp log(msg), do: Mix.shell().info(msg)
end
