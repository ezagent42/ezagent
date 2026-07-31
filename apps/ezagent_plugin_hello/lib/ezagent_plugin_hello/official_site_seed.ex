defmodule EzagentPluginHello.OfficialSiteSeed do
  @moduledoc """
  Governed, absence-gated provisioner for the official Hello session.

  The founder is an existing non-admin user selected by this deployment's
  seed configuration. This module never creates a user or falls back to a
  hard-coded principal.

  ## INTERIM responder wiring (removed by the #1667 structural fix)

  Beyond provisioning, `ensure/0` durably re-wires the live-prod WORKAROUND
  that keeps the 官网 answering after a reseed:

    1. the `llm` greeter member's DeepSeek credential, dispatched via the
       COMPARE-AND-SET `:put_api_key_if_absent` action from
       `DEEPSEEK_API_KEY` (absent env → skipped with a warning, never a
       crash, never a hardcoded key; unreadable agent → skipped with a
       warning, NEVER a blind overwrite of an operator-rotated key);
    2. a session-scoped `MentionRouting` delivery rule
       (`in_session(官网) → [llm agent]`) so every message in the session
       reaches the keyed responder directly — reconciled ATOMICALLY to
       exactly one seed-owned row (`rule_set: "official-site-interim"`,
       unique-index-guarded) through the site scope's OWN
       `Ezagent.ActionSet.Routing` dispatch (admin-issued, action-specific
       cap), never a direct `RuleStore` write.

  This bypasses the native front-desk→concierge→`call_llm` chain, which is
  broken (`call_llm` completes as `entity://system/user/admin`, who holds no
  `Agent.Complete` cap → `:unauthorized`). The STRUCTURAL fix — native
  front-desk→llm reply via a composition-cap, de-admin completion — lands
  with the socialware answer-routing work (#1667, jjkysy); when it lands,
  the direct `in_session` delivery rule (2) is removed. Do NOT build the
  native chain here.
  """

  require Logger

  alias Ezagent.Entity.{Profile, User}
  alias Ezagent.Routing.{Matcher, RuleStore}
  alias Ezagent.Socialware.ExternalFeed
  alias EzagentPluginHello.{FusionSeed, Members}

  @name "ezagent-official"

  # The `llm` member's provider flavor (curl) + its api_keys slice entry.
  @llm_role "llm"
  @llm_provider "deepseek"
  @llm_api_key_env "DEEPSEEK_API_KEY"

  @type outcome ::
          {:ok, {:provisioned, URI.t(), String.t()}}
          | {:ok, {:already_provisioned, URI.t()}}
          | {:error, term()}

  @spec site_uri() :: URI.t()
  @doc "Returns the canonical URI of the official Hello site session."
  def site_uri, do: Ezagent.URI.session(EzagentPluginHello.home_workspace(), :hello, @name)

  @spec boot_enabled?() :: boolean()
  @doc "Whether deployment boot should provision the official Hello site."
  def boot_enabled?, do: Application.get_env(:ezagent_plugin_hello, :site_seed_boot, false)

  @spec ensure() :: outcome()
  @doc "Ensures the official Hello site exists, without creating a founder user."
  def ensure do
    with {:ok, owner} <- resolve_founder() do
      outcome =
        case current_page() do
          {:present, uri} -> {:ok, {:already_provisioned, uri}}
          :absent -> provision(owner)
        end

      # INTERIM workaround wiring (see the moduledoc): runs on EVERY ensure —
      # provisioned AND already-provisioned — so a reseed that dropped the
      # credential/rule, or a live site that never had them, self-heals on
      # the next boot. Each leg is absence-gated; wiring failures degrade to
      # a warning, never to a seed failure.
      case outcome do
        {:ok, {:provisioned, uri, _turn_id}} -> wire_responder(uri)
        {:ok, {:already_provisioned, uri}} -> wire_responder(uri)
        {:error, _} -> :ok
      end

      outcome
    end
  end

  defp resolve_founder do
    home = EzagentPluginHello.home_workspace()

    with email when is_binary(email) and email != "" <- founder_email(),
         %Profile{entity_uri: entity_uri} <- Profile.by_email(email),
         {:ok, %URI{} = founder} <- Ezagent.URI.parse(entity_uri),
         true <- Ezagent.Capability.workspace_of(founder) == Ezagent.URI.workspace(home),
         :ok <- ensure_startable_principal(founder) do
      {:ok, founder}
    else
      nil -> {:error, :official_site_founder_not_found}
      false -> {:error, :official_site_founder_wrong_workspace}
      {:error, :not_registered} -> {:error, :official_site_founder_not_registered}
      _ -> {:error, :official_site_founder_unconfigured}
    end
  end

  # A `Profile` row is decoupled from the `users` provisioning row (separate
  # tables, no FK), so a configured founder email can resolve to an entity that
  # has a Profile but NO registered — or a soft-disabled — user. Such a founder
  # is not a startable principal: the owner member-cap `identity.absorb_cap` at
  # session-create time has no durable user Kind to land on, so ownership is
  # non-durable (dropped on the next boot's `Users.list_all` respawn) and on
  # some deploys manifests as the `:no_such_actor` absorb retry loop (#207).
  # #1576's contract is "the founder is an EXISTING non-admin user" — enforce
  # it here and fail loud so the deployment provisions/enables the real user,
  # never soften by creating one or falling back to a hard-coded principal.
  defp ensure_startable_principal(%URI{} = founder) do
    cond do
      is_nil(Ezagent.Users.get_by_uri(founder)) -> {:error, :not_registered}
      Ezagent.Users.disabled?(founder) -> {:error, :not_registered}
      true -> :ok
    end
  end

  # Deployment provisioning loads this value from that environment's seed.env.
  # It is intentionally a reference to an already-created user, never a secret.
  defp founder_email do
    Application.get_env(:ezagent_plugin_hello, :official_site_founder_email)
  end

  defp current_page do
    uri = site_uri()

    case ExternalFeed.snapshot(uri, User.admin_uri()) do
      {:ok, %{page: page}} when not is_nil(page) -> {:present, uri}
      _ -> :absent
    end
  end

  defp provision(owner) do
    case FusionSeed.run(workspace: EzagentPluginHello.home_workspace(), name: @name, owner: owner) do
      {:ok, %{session_uri: uri, turn_id: turn_id}} -> {:ok, {:provisioned, uri, turn_id}}
      {:error, _reason} = error -> error
      other -> {:error, {:unexpected_seed_result, other}}
    end
  end

  # --- INTERIM responder wiring (removed by the #1667 structural fix) ------

  # Seed-owned routing-rule marker. Every delivery-rule row this workaround
  # installs carries this `rule_set`, so a reseed can tell its OWN rows from
  # operator/template rows and reconcile to EXACTLY ONE row. The same literal
  # backs the partial unique index
  # `routing_rules_official_site_interim_unique` (repo_pg migration
  # 20260731000000) — the DB-level duplicate guard for concurrent deploy-node
  # reseeds. Keep the two in sync.
  @delivery_rule_set "official-site-interim"

  defp wire_responder(%URI{} = site_uri) do
    best_effort("responder wiring", fn ->
      case Members.role_uri(site_uri, @llm_role) do
        {:ok, %URI{} = llm_uri} ->
          ensure_llm_credential(llm_uri)
          ensure_delivery_rule(site_uri, llm_uri)

        :error ->
          Logger.warning(
            "hello official-site seed: no #{@llm_role} member in #{URI.to_string(site_uri)} — " <>
              "skipped responder wiring"
          )
      end
    end)

    :ok
  end

  # (a) The DeepSeek credential on the llm greeter agent, mirroring the
  # live-prod `:put_api_key` dispatch. Gated on a TRI-STATE read of the
  # agent's api_keys slice; a missing env key skips gracefully (keyless dev
  # stays keyless). The whole leg runs inside a secret-aware boundary: the
  # key must never reach a log line, and a failure must never fail the seed.
  defp ensure_llm_credential(%URI{} = llm_uri) do
    best_effort("llm credential wiring", [secret?: true], fn ->
      case System.get_env(@llm_api_key_env) do
        key when is_binary(key) and key != "" ->
          case llm_key_state(llm_uri) do
            :present ->
              :ok

            :absent ->
              put_llm_api_key_if_absent(llm_uri, key)

            :unreadable ->
              Logger.warning(
                "hello official-site seed: the #{@llm_role} agent's :api_keys slice is " <>
                  "unreadable (agent rehydrating / not ready) — skipped the #{@llm_provider} " <>
                  "credential wiring rather than risk overwriting an operator-rotated key; " <>
                  "the next boot's ensure/0 retries"
              )
          end

        _ ->
          Logger.warning(
            "hello official-site seed: #{@llm_api_key_env} not set — the 官网 llm responder " <>
              "stays keyless (set it to wire the DeepSeek credential)"
          )
      end
    end)
  end

  # TRI-STATE read (codex must-fix #1): `Kind.read/3` can return
  # `{:error, {:not_ready, _}}` while a cold agent rehydrates (ReadyGate) or
  # `{:error, :not_created}` for a never-durably-created one. Treating ANY
  # read failure as "absent" would re-dispatch a put and CLOBBER an
  # operator-rotated key on a deploy-time readiness timeout — so only a
  # successful read classifies present/absent; every error is :unreadable.
  defp llm_key_state(%URI{} = llm_uri) do
    case Ezagent.Kind.read(llm_uri, :api_keys) do
      {:ok, slice} when is_map(slice) ->
        slice
        |> Map.get(:keys, %{})
        |> Map.get(@llm_provider)
        |> case do
          key when is_binary(key) and key != "" -> :present
          _ -> :absent
        end

      {:error, _} ->
        :unreadable
    end
  end

  # The same dispatch shape the curl flavor's own credential cascade uses
  # (`Ezagent.PluginCurlAgent.Template.put_target_api_key/3`) — an
  # admin-issued narrow cap presented by the agent ITSELF (self-authority
  # over its own :api_keys slice) — but targeting the COMPARE-AND-SET
  # `:put_api_key_if_absent` action: the set-if-empty check runs inside the
  # agent's serialized action path, so two racing seeders can't both observe
  # absence and the loser's key never lands.
  defp put_llm_api_key_if_absent(%URI{} = llm_uri, key) do
    target = Ezagent.URI.with_action(llm_uri, :api_keys, :put_api_key_if_absent)

    with {:ok, cap} <-
           Ezagent.Cap.issue_for_action({:admin, User.admin_uri()}, llm_uri, target),
         {:ok, _result} <-
           Ezagent.Invocation.dispatch(%Ezagent.Invocation{
             target: target,
             mode: :call,
             args: %{provider: @llm_provider, key: key},
             ctx: %{
               caller: llm_uri,
               authenticated_principal: llm_uri,
               caps: [cap],
               reply: :sync
             },
             origin: :trusted_internal
           }) do
      :ok
    else
      {:error, reason} ->
        Logger.warning(
          "hello official-site seed: failed to wire the #{@llm_provider} credential on " <>
            "#{URI.to_string(llm_uri)} (#{credential_error_class(reason)})"
        )
    end
  end

  # Credential-leg error reasons may embed the plaintext key (handler
  # bad-args echoes, GenServer.call exit payloads carry the invocation
  # args) — reduce them to a key-free class tag before logging.
  defp credential_error_class(%{__exception__: true} = e), do: inspect(e.__struct__)
  defp credential_error_class({:error, reason}), do: credential_error_class(reason)
  defp credential_error_class({first, _}) when is_atom(first), do: Atom.to_string(first)
  defp credential_error_class({first, _, _}) when is_atom(first), do: Atom.to_string(first)
  defp credential_error_class(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp credential_error_class(_), do: "unknown"

  # (b) The session-scoped delivery rule: EVERY message in the 官网 session is
  # delivered directly to the (keyed) llm agent. ATOMIC RECONCILE to exactly
  # ONE seed-owned row (`rule_set: @delivery_rule_set`,
  # `receivers == [llm_uri]`, `enabled: true`, `source: "admin"`): stale
  # owned rows — incl. legacy pre-marker rows whose concrete receiver points
  # at a since-changed/removed llm member — are deleted, the correct row is
  # inserted when missing, and the live registry is ALWAYS rehydrated (a
  # durable row without registry hydration is a non-delivering rule).
  #
  # All mutations dispatch through the site scope's OWN routing ActionSet
  # (`Ezagent.ActionSet.Routing` on the session Kind) presenting an
  # admin-issued, action-specific cap minted via `Cap.issue_for_action`
  # (codex must-fix #3) — the mutation passes the scope-bound CapBAC
  # chokepoint instead of laundering an admin-attributed row around it.
  defp ensure_delivery_rule(%URI{} = site_uri, %URI{} = llm_uri) do
    best_effort("官网 delivery-rule wiring", fn ->
      table = Ezagent.Routing.Resolver.default_routing_table()
      matcher_json = Matcher.to_json(Matcher.in_session(site_uri))
      receiver = uri_to_string(llm_uri)

      owned =
        table
        |> RuleStore.list()
        |> Enum.filter(&owned_delivery_rule?(&1, matcher_json))

      {good, stale} =
        Enum.split_with(owned, fn rule ->
          rule.rule_set == @delivery_rule_set and
            rule.matcher_data == matcher_json and
            rule.receivers == [receiver] and
            rule.enabled and
            rule.source == RuleStore.admin_source()
        end)

      case good do
        [_keep | duplicates] ->
          Enum.each(duplicates ++ stale, &delete_delivery_rule(table, site_uri, &1))

        [] ->
          Enum.each(stale, &delete_delivery_rule(table, site_uri, &1))
          add_delivery_rule(table, site_uri, llm_uri)
      end

      # ALWAYS rehydrate — also when a good row already existed (the registry
      # ETS is per-boot; a reseed that changed nothing on disk still owes the
      # live registry the row).
      :ok = RuleStore.load_into_registry(table)
    end)
  end

  # A row is OURS to reconcile when it carries the seed-owned rule_set
  # marker, or it is a legacy pre-marker row from this same workaround
  # (admin-attributed in_session rule for THIS session without a rule_set).
  # The legacy leg is what garbage-collects rows pointing at a removed llm
  # member — those would otherwise keep delivering to a dead agent.
  defp owned_delivery_rule?(rule, matcher_json) do
    rule.rule_set == @delivery_rule_set or
      (is_nil(rule.rule_set) and rule.matcher_data == matcher_json and
         rule.created_by == uri_to_string(User.admin_uri()))
  end

  defp add_delivery_rule(table, %URI{} = site_uri, %URI{} = llm_uri) do
    args = %{
      table: table,
      matcher_json: Matcher.to_json(Matcher.in_session(site_uri)),
      receivers: [uri_to_string(llm_uri)],
      opts: [
        created_by: User.admin_uri(),
        source: RuleStore.admin_source(),
        rule_set: @delivery_rule_set
      ]
    }

    case dispatch_rule_mutation(site_uri, :add_rule, args) do
      {:ok, %{id: _id}} ->
        :ok

      {:error, reason} ->
        # The `routing_rules_official_site_interim_unique` partial unique
        # index turns a two-node concurrent insert into a ConstraintError on
        # the loser — surfaced through dispatch as {:behavior_exception, …}.
        # The winner's row is exactly the row we wanted; adopt it.
        if delivery_rule_now_present?(table, site_uri, llm_uri) do
          Logger.warning(
            "hello official-site seed: 官网 delivery-rule insert raced a concurrent seeder " <>
              "(#{credential_error_class(reason)} — likely the unique-index guard); " <>
              "adopted the existing row"
          )
        else
          Logger.warning(
            "hello official-site seed: failed to add the 官网 delivery rule: " <>
              "#{inspect(reason, limit: 6)}"
          )
        end
    end
  end

  defp delivery_rule_now_present?(table, %URI{} = site_uri, %URI{} = llm_uri) do
    matcher_json = Matcher.to_json(Matcher.in_session(site_uri))
    receiver = uri_to_string(llm_uri)

    table
    |> RuleStore.list()
    |> Enum.any?(fn rule ->
      rule.rule_set == @delivery_rule_set and rule.matcher_data == matcher_json and
        rule.receivers == [receiver] and rule.enabled
    end)
  end

  defp delete_delivery_rule(table, %URI{} = site_uri, rule) do
    case dispatch_rule_mutation(site_uri, :delete_rule, %{table: table, id: rule.id}) do
      {:ok, %{deleted: _}} ->
        :ok

      {:error, reason} ->
        # A concurrent seeder may have deleted the same row first — benign.
        Logger.warning(
          "hello official-site seed: stale 官网 delivery rule #{rule.id} delete returned " <>
            "#{inspect(reason, limit: 4)} (continuing reconcile)"
        )
    end
  end

  # One routing dispatch with an admin-issued, action-specific cap. The cap
  # is minted for the site SESSION as grantee/presenter — the seed acts on
  # behalf of the site scope itself, so a corrupted member edge can never be
  # laundered into an admin-attributed durable receiver by an ambient
  # wildcard (codex must-fix #3).
  defp dispatch_rule_mutation(%URI{} = site_uri, action, args) do
    target = Ezagent.URI.with_action(site_uri, :routing, action)

    with {:ok, cap} <-
           Ezagent.Cap.issue_for_action({:admin, User.admin_uri()}, site_uri, target),
         {:ok, result} <-
           Ezagent.Invocation.dispatch(%Ezagent.Invocation{
             target: target,
             mode: :call,
             args: args,
             ctx: %{
               caller: site_uri,
               authenticated_principal: site_uri,
               caps: [cap],
               reply: :sync
             },
             origin: :trusted_internal
           }) do
      {:ok, result}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # codex must-fix #4: EVERY best-effort wiring leg runs inside a boundary
  # that rescues exceptions AND catches exits/throws (RuleStore/cap
  # issuance/dispatch/load_into_registry can all raise or exit — e.g. a
  # disk-full DB error), logs a warning, and always returns :ok. A wiring
  # failure must NEVER fail the seed or crash the boot task. With
  # `secret?: true` the log carries ONLY the error class — exception
  # messages and exit payloads can embed the credential.
  defp best_effort(label, fun), do: best_effort(label, [], fun)

  defp best_effort(label, opts, fun) when is_function(fun, 0) do
    _ = fun.()
    :ok
  rescue
    e ->
      detail =
        if Keyword.get(opts, :secret?, false) do
          inspect(e.__struct__)
        else
          Exception.message(e)
        end

      Logger.warning("hello official-site seed: #{label} failed: #{detail}")
      :ok
  catch
    kind, reason ->
      detail =
        if Keyword.get(opts, :secret?, false) do
          Atom.to_string(kind)
        else
          "#{kind}: #{inspect(reason, limit: 6, printable_limit: 200)}"
        end

      Logger.warning("hello official-site seed: #{label} failed (#{detail})")
      :ok
  end

  # Off-the-receiver-line URI serializer (keeps the membership comparison
  # clear of the uri_query.scan `uri_string_key` heuristic — the repo's
  # `uri_to_string/1` convention; persisted rule receivers are strings).
  defp uri_to_string(%URI{} = uri), do: URI.to_string(uri)
end
