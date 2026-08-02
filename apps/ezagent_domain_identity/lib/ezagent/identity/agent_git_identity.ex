defmodule Ezagent.Identity.AgentGitIdentity do
  @moduledoc """
  SSH 凭据 1b — decides WHETHER an agent gets a git identity, and WHOSE, then
  hands the write to `Ezagent.Credential.GitIdentityRuntime` (core).

  ## 一条 cap 同时是三样东西

  The agent's `read_ssh_key` capability is:

  * the **switch** — hold it and the identity is materialized; don't and nothing
    happens at all (no dispatch, no files, no log line)
  * the **authorization** — it is 1a's own cap, checked by the normal step-5.5
    gate on the dispatch
  * the **pointer** — `cap.instance` IS the User whose key gets read

  **Nothing is derived.** There is deliberately no "resolve the agent's owner"
  step: `Ezagent.WorkspacePlacement.owner_of/1` returns the node's
  `RuntimeIdentity` (a federation-placement concept), not a workspace's owning
  user, and the recipe cap channel cannot express a cap pointing at a User —
  `Ezagent.Agent.Recipe.CapMint.mint/3` itself takes `kind`/`instance` as
  parameters (it is generic), but its ONLY production call site
  (`Ezagent.ActionSet.Workspace.AgentCreate.RoleStep.mint_and_grant_caps/4`,
  `role_step.ex:194-200`) hardwires `kind: :agent, instance: agent_uri` for
  every recipe-materialized agent — so a recipe cap can only ever point at the
  agent itself, never at a User. Making the cap the pointer means the switch
  and the subject are the same fact and cannot drift apart.

  Grant it with `mix ezagent.agent.grant_git_identity <agent_uri> <user_uri>`.

  **Exactly one cap, or none — never a silent pick among several.** Holding
  TWO OR MORE `read_ssh_key` caps pointing at DIFFERENT Users is structurally
  possible — each cap's identity key includes `instance`
  (`Ezagent.Capability.identity_key/1`), so two caps aimed at two Users are
  two DISTINCT caps, not something the grant layer rejects as a duplicate —
  and is a real operational path: re-pointing an agent from User A to User B
  by granting B without first revoking A. `materialize/1` treats that state
  as a configuration error (`{:error, {:ambiguous_git_identity, _}}`), never
  a "pick one": `Ezagent.Identity.list_caps_for/1` returns a `MapSet`, whose
  enumeration order carries no operator-visible meaning, so silently picking
  one would make the choice of identity depend on term hashing, not operator
  intent — and the wrong pick fails no louder than the right one (worst case:
  pushes as the WRONG audited identity).

  ## 这也是 B2′ 与 A1 的切换点

  A1（平台持 key、agent 不持）= 不发这条 cap。切换粒度**是 agent**，不是仓库
  —— key 归 User，一个 session 里只要有一个仓库走 B2′，key 就覆盖了该 User 的
  所有仓库（见 1b design §10）。

  ## 部署契约

  同一部署内，两个 agent 是否隔离，完全取决于有没有各自发这条 cap。
  跨租户隔离靠**不共享部署**（workspace = 部署单元），代码无强制。
  """

  require Logger

  alias Ezagent.ActionSet.UserSshIdentity
  alias Ezagent.Credential.GitIdentityRuntime

  @behavior_module UserSshIdentity
  @action :read_ssh_key

  @doc """
  Materialize `agent_uri`'s git identity, if it is authorized for one.

  * `{:ok, env}` — materialized; merge `env` into the agent subprocess env
  * `{:ok, :none}` — **the default**: no cap, nothing done, nothing logged
  * `{:error, reason}` — authorized but something is misconfigured (or the
    agent's cap set is ambiguous — see the moduledoc); the caller MUST NOT
    fail the spawn over it (a git identity is a capability of the agent, not
    a precondition for its existence)

  Never raises — and never lets an EXIT out of `Ezagent.Invocation.dispatch/1`
  (a `GenServer.call` timeout, or the target handler crashing mid-call)
  propagate to the caller either. `Ezagent.Invocation.call_live_target/3`
  deliberately RE-RAISES both rather than mapping them to `{:error, _}` (only
  a dead/closing target becomes a tuple — see invocation.ex:485-490), so this
  module has to be the one to stop them. A caller on the spawn path taken
  down by either would turn a recoverable git-identity misconfiguration into
  an agent that cannot start at all — exactly what design §3.2 rules out.
  """
  @spec materialize(URI.t()) :: {:ok, map()} | {:ok, :none} | {:error, term()}
  def materialize(%URI{} = agent_uri) do
    case dispatch_caps(agent_uri) do
      [] ->
        # 设计 §6.1 —— THE step that makes cap revocation take effect. Without
        # this wipe, revoking the cap only removes the env var while the key
        # stays on the agent's filesystem, fully usable via its own
        # `git -c core.sshCommand=...`. Cheap: an rm_rf on a path that does
        # not exist for nearly every agent, every spawn.
        GitIdentityRuntime.wipe(agent_uri)
        {:ok, :none}

      [cap] ->
        with {:ok, private_key} <- read_private_key(agent_uri, cap),
             {:ok, env} <- GitIdentityRuntime.write(agent_uri, private_key) do
          {:ok, env}
        else
          {:error, reason} ->
            # `GitIdentityRuntime.write/2` wipes on its OWN failures, but a
            # `read_private_key/2` failure happens BEFORE write is ever called
            # — nothing would clear a key left by an earlier successful spawn.
            # 设计 §6.1: every outcome except `{:ok, env}` clears the dir.
            GitIdentityRuntime.wipe(agent_uri)
            report(agent_uri, cap, reason)
        end

      [_, _ | _] = caps ->
        # C2 — two or more `read_ssh_key` caps pointing at different Users is
        # structurally possible (see moduledoc) and MUST fail loud, not pick
        # one silently. Sorting the `MapSet` into some deterministic order
        # would only make the wrong pick REPRODUCIBLE, not correct (memory
        # `feedback-gate-targets-accidents-not-attackers`: this is an
        # accident-avoidance gate, not a security boundary).
        GitIdentityRuntime.wipe(agent_uri)
        report_ambiguous(agent_uri, caps)
    end
  rescue
    # `GitIdentityDir.path/1` raises on a non-agent URI; `user_uri_of/1`'s
    # `Ezagent.URI.new!/1` call can also raise on a malformed `cap.instance`.
    # A cleanup/materialize helper must never take the spawn path down with
    # it — and per 设计 §6.1, every non-`{:ok, env}` outcome must leave the
    # git-identity dir empty, this one included (`wipe/1` never raises on its
    # own — Task 2 already broadened its rescue — so it is always safe here).
    e ->
      GitIdentityRuntime.wipe(agent_uri)
      {:error, {:git_identity_materialize_crashed, Exception.message(e)}}
  catch
    # C1 — `Ezagent.Invocation.dispatch/1`'s `:call` mode deliberately
    # RE-RAISES both a `GenServer.call` timeout EXIT and a target-handler-
    # crash EXIT rather than mapping either to an `{:error, _}` tuple
    # (`Ezagent.Invocation.call_live_target/3`, invocation.ex:485-490 — only
    # a dead/closing target is turned into a tuple there). `rescue` above
    # does NOT see this: an EXIT signal is not an Elixir exception. Left
    # uncaught, a User Kind that is alive but busy (mid keygen, or just
    # slow) — or one whose handler crashes mid-call — would take THIS
    # process down with it: exactly the failure this module's own "Never
    # raises" contract exists to rule out. Mirrors the repo's existing
    # answer to the same problem: `Ezagent.Invocation.lazy_spawn_from_snapshot/1`'s
    # `catch` (invocation.ex:400-408) and
    # `apps/ezagent_plugin_git_workflow/.../cap_backed.ex`'s
    # `dispatch_catching_exit/1` (whose own comment: "rather than an exit
    # that takes the caller down"). Catches ANY exit reason, not only the
    # timeout shape `{:timeout, _call}`: `cap_backed.ex` can match narrowly
    # because ITS downstream targets are stable providers where a handler
    # crash is not an expected failure; this module's contract ("Never
    # raises", no qualifier) is unconditional, and a handler crash inside
    # 1a's `UserSshIdentity` is re-raised the exact same way a timeout is.
    :exit, reason ->
      GitIdentityRuntime.wipe(agent_uri)
      {:error, {:git_identity_materialize_exited, reason}}
  end

  @doc """
  The caps this agent would dispatch with — exactly the `read_ssh_key` caps it
  holds, and nothing else.

  Public so the narrow-authorization property is directly assertable: passing
  the agent's FULL cap set to the dispatch would carry every other authority it
  owns into a credential read (`Ezagent.Credential.GrantCap`'s moduledoc states
  the same rule for the source-read path: "The caller passes this SINGLE cap
  as the dispatch caps ... never a broad set").

  Does not judge cardinality — `materialize/1` decides what zero, one, or
  several mean (see its `[_, _ | _]` clause).
  """
  @spec dispatch_caps(URI.t()) :: [Ezagent.Capability.t()]
  def dispatch_caps(%URI{} = agent_uri) do
    agent_uri
    |> Ezagent.Identity.list_caps_for()
    |> Enum.filter(&ssh_read_cap?/1)
  end

  # ── internals ──────────────────────────────────────────────────────────────

  # A cap whose `instance` is the wildcard `:any` is NOT a pointer — it names no
  # User. Treating it as "on" would leave `user_uri_of/1` with nothing to
  # dispatch at. Require a concrete instance: the switch and the subject are the
  # same fact, so a cap that cannot name a subject cannot be a switch.
  defp ssh_read_cap?(%Ezagent.Capability{
         behavior: @behavior_module,
         action: @action,
         instance: instance
       }),
       do: concrete_instance?(instance)

  defp ssh_read_cap?(_), do: false

  defp concrete_instance?(%URI{}), do: true
  defp concrete_instance?(s) when is_binary(s) and s != "", do: true
  defp concrete_instance?(_), do: false

  defp read_private_key(agent_uri, cap) do
    target = Ezagent.URI.with_action(user_uri_of(cap), :user_ssh_identity, @action)

    invocation = %Ezagent.Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: %{},
      ctx: %{
        caller: agent_uri,
        authenticated_principal: agent_uri,
        # THE narrow cap — not the agent's full set. See `dispatch_caps/1`.
        caps: MapSet.new([cap]),
        reply: {:caller_inbox, self()}
      }
    }

    invocation
    |> Ezagent.Invocation.dispatch()
    |> interpret_read_result()
  end

  @doc false
  # C4 — this is 1b's OWN seam: the mapping from `Ezagent.Invocation.dispatch/1`'s
  # raw `:call`-mode return to the `{:ok, pem} | {:error, reason}` contract
  # `read_private_key/2` needs. Exposed (not `defp`) and directly unit-tested
  # so every branch — success, both of 1a's distinguished error atoms, an
  # undistinguished error, and a malformed/unexpected shape — has an
  # assertion that goes red if its clause is deleted (extracting only the
  # error clauses would leave the success/`other` branches unguarded and let
  # the tested function's clause set drift from the real call site's).
  #
  # Named to avoid "Invocation" vocabulary on purpose, and worth being
  # explicit about what this seam does and does NOT pin: it pins 1b's OWN
  # mapping ONLY — not that 1a's `handle_read_ssh_key/2` still emits
  # `:ssh_identity_unavailable` for a corrupted identity. THAT is 1a's own
  # contract, independently guarded by
  # `user_ssh_identity_test.exs:309/319/332/374/381/395`. Two ends, two sets
  # of tests; the seam is documented here instead of assumed.
  @spec interpret_read_result(term()) :: {:ok, binary()} | {:error, term()}
  def interpret_read_result({:ok, %{private_key: key}}) when is_binary(key) do
    {:ok, key}
  end

  # 1a deliberately separates these two. Keep them separate here: one means
  # "the operator granted a cap but never generated a key" (fix: generate),
  # the other means "a key exists but its state is corrupt" (fix: revoke +
  # regenerate). Collapsing them throws away a distinction 1a spent a full
  # review round getting right.
  def interpret_read_result({:error, :ssh_identity_absent}) do
    {:error, :owner_has_no_key}
  end

  def interpret_read_result({:error, :ssh_identity_unavailable}) do
    {:error, {:owner_key_unavailable, :ssh_identity_unavailable}}
  end

  def interpret_read_result({:error, reason}) do
    {:error, {:ssh_key_read_failed, reason}}
  end

  # M5: unreachable in practice TODAY — 1a's `identity_state/1`
  # (`user_ssh_identity.ex:326-334`) only returns `{:ok, priv}` once
  # `valid_private_key?(priv)` already held, so a successful
  # `handle_read_ssh_key/2` call structurally cannot reach this module with a
  # non-binary `private_key`. That safety lives in 1a's guard, not here —
  # which is exactly why this clause stays defensive instead of assuming the
  # guard can never change. Shape-only, never the raw value: `other` could,
  # in principle, be anything a misbehaving Behavior returns, and this must
  # never become a leak surface even in that case.
  def interpret_read_result(_other) do
    {:error, {:ssh_key_read_unexpected, :malformed_result}}
  end

  # The cap's `instance` IS the User to read from — the pointer half of the
  # moduledoc's "one cap, three jobs".
  defp user_uri_of(%Ezagent.Capability{instance: %URI{} = uri}), do: uri

  defp user_uri_of(%Ezagent.Capability{instance: uri}) when is_binary(uri),
    do: Ezagent.URI.new!(uri)

  @doc false
  # M2/M5 — computed ONCE per report call (previously `report/3` called
  # `user_uri_of/1` TWICE: once for telemetry, once for the log line). A
  # malformed `cap.instance` makes `user_uri_of/1` raise (via
  # `Ezagent.URI.new!/1`) — with two call sites, the SECOND raise happened
  # from inside `report/3` itself, got swallowed by `materialize/1`'s
  # top-level `rescue`, and replaced the real `reason` this function exists
  # to surface with a generic `:git_identity_materialize_crashed`. Falls back
  # to `inspect/1` — shape only, and `cap.instance` is a URI or URI-shaped
  # string, never key material, so this never risks leaking the private key.
  #
  # Exposed (not `defp`) so the fallback is directly unit-testable: no
  # legitimate cap can reach this module with a malformed `instance`
  # end-to-end (a signed cap's `instance` is set by `Ezagent.Cap.Authority`
  # at issuance, not attacker/caller-controlled — mirrors why the sibling
  # `:any`-instance case in `agent_git_identity_test.exs` also can't be
  # constructed end-to-end), so this is defense-in-depth exercised directly
  # rather than through an (unreachable) full absorb→dispatch path.
  @spec user_uri_string(Ezagent.Capability.t()) :: String.t()
  def user_uri_string(cap) do
    URI.to_string(user_uri_of(cap))
  rescue
    _ -> inspect(cap.instance)
  end

  # Authorized-but-broken must be NOISY (the operator granted a cap and expects
  # git to work), while the no-cap case above is silent (it is the default state
  # of nearly every agent — a log line there would be pure noise).
  #
  # `reason` never carries key material: `GitIdentityRuntime` strips content
  # from its error tuples, and 1a's action errors are bare atoms.
  defp report(agent_uri, cap, reason) do
    user_str = user_uri_string(cap)

    :telemetry.execute(
      [:ezagent, :git_identity, :materialize_failed],
      %{count: 1},
      %{agent: URI.to_string(agent_uri), user: user_str, reason: reason}
    )

    message =
      "git identity NOT materialized for #{URI.to_string(agent_uri)} " <>
        "(authorized to read #{user_str}): #{inspect(reason)}. " <>
        remediation(reason, user_str)

    log(reason, message)

    {:error, reason}
  end

  # C2 — same telemetry event, distinct message shape: no single "authorized
  # to read X" framing applies when the agent holds several conflicting
  # pointers at once.
  defp report_ambiguous(agent_uri, caps) do
    user_strs = Enum.map(caps, &user_uri_string/1)
    reason = {:ambiguous_git_identity, user_strs}

    :telemetry.execute(
      [:ezagent, :git_identity, :materialize_failed],
      %{count: 1},
      %{agent: URI.to_string(agent_uri), reason: reason}
    )

    message =
      "git identity NOT materialized for #{URI.to_string(agent_uri)}: holds " <>
        "#{length(caps)} read_ssh_key caps pointing at DIFFERENT Users " <>
        "(#{Enum.join(user_strs, ", ")}). #{remediation(reason, nil)}"

    log(reason, message)

    {:error, reason}
  end

  # M1: not every noisy case is the same severity. 设计 §3.1 draws
  # `:owner_has_no_key` (a soft misconfiguration: granted but never
  # generated) apart from everything else (a harder failure: a corrupted
  # identity, an ambiguous cap set, or a node config gap).
  defp log(:owner_has_no_key, message), do: Logger.warning(message)
  defp log(_reason, message), do: Logger.error(message)

  # C5 — both give a concrete next step, not just the abstract action name.
  # No CLI task exists yet for :generate_ssh_key/:revoke_ssh_key (1a wires
  # them to World UI, not a mix task — see 1a design §2 ①), so "concrete"
  # here means naming the exact action(s) AND the exact User, not a
  # copy-paste shell command that does not exist.
  #
  # Exposed (not `defp`) so the `{:owner_key_unavailable, _}` clause is
  # directly unit-testable: C4 established that state has no public,
  # end-to-end-constructible path through `materialize/1` (1a only exposes
  # "set everything" and "clear everything"), so the only way to pin this
  # clause's TEXT (as opposed to its error SHAPE, which
  # `interpret_read_result/1` already pins) is to call it directly.
  @doc false
  @spec remediation(term(), String.t() | nil) :: String.t()
  def remediation(:owner_has_no_key, user_str),
    do:
      "The User #{user_str} has no SSH identity — generate one for them " <>
        "(World UI SSH tab if wired up, or dispatch :generate_ssh_key to " <>
        "that User directly; there is no mix task for this yet)."

  def remediation({:owner_key_unavailable, _}, user_str),
    do:
      "The User #{user_str}'s SSH identity is corrupt — first :revoke_ssh_key, " <>
        "then :generate_ssh_key, to rebuild it clean; a half-identity state " <>
        "can only be cleared this way (see " <>
        "Ezagent.ActionSet.UserSshIdentity.handle_revoke_ssh_key/2)."

  def remediation({:ambiguous_git_identity, user_strs}, _user_str),
    do:
      "This agent holds read_ssh_key caps for MULTIPLE Users " <>
        "(#{Enum.join(user_strs, ", ")}) — revoke all but the intended one " <>
        "via `Ezagent.EntityCaps.revoke/2` before the next spawn."

  def remediation(:known_hosts_unconfigured, _user_str),
    do:
      "No node known_hosts configured — run `mix ezagent.git.known_hosts github.com --out <path>` " <>
        "and set `config :ezagent_core, :git_known_hosts_path, \"<path>\"`."

  def remediation({:known_hosts_unreadable, _}, _user_str),
    do: "The configured :git_known_hosts_path is unreadable — check the path and permissions."

  def remediation(_, _user_str), do: ""
end
