defmodule EzagentPluginHello.OfficialSiteSeed do
  @moduledoc """
  Governed, absence-gated provisioner for the official Hello session.

  The founder is an existing non-admin user selected by this deployment's
  seed configuration. This module never creates a user or falls back to a
  hard-coded principal.

  ## Responder credential wiring

  Beyond provisioning, `ensure/0` absence-gates the `llm` member's DeepSeek
  credential through `:put_api_key_if_absent`. User messages enter through the
  manifest-declared Session ingress; the seed removes any seed-owned legacy
  `in_session → llm` rule left by the retired interim workaround.
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

      # Responder maintenance (see the moduledoc): runs on EVERY ensure —
      # provisioned AND already-provisioned — so a missing credential is
      # restored and any retired direct-delivery rule is removed on the next
      # boot. Maintenance failures degrade to a warning, never a seed failure.
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

  # --- responder credential + retired-rule cleanup -------------------------

  # Marker used only to identify and remove rows installed by the retired direct
  # delivery workaround. It matches the historical database migration literal.
  @delivery_rule_set "official-site-interim"

  defp wire_responder(%URI{} = site_uri) do
    remove_direct_delivery_rules(site_uri)

    best_effort("responder wiring", fn ->
      case Members.role_uri(site_uri, @llm_role) do
        {:ok, %URI{} = llm_uri} ->
          ensure_llm_credential(llm_uri)

        :error ->
          Logger.warning(
            "hello official-site seed: no #{@llm_role} member in #{URI.to_string(site_uri)} — " <>
              "skipped responder wiring"
          )
      end
    end)

    :ok
  end

  # The DeepSeek credential on the llm greeter agent, mirroring the
  # live-prod credential dispatch. The bounded TRI-STATE read preserves the
  # deploy-time readiness contract: only a successful read can classify the
  # provider key as present/absent; an unreadable or not-ready slice skips the
  # credential leg without entering dispatch's longer WAIT-then-serve path.
  # When absent, the `:put_api_key_if_absent` COMPARE-AND-SET performs the final
  # check inside the agent's serialized action path, so racing seeders still
  # cannot overwrite an operator-rotated key. A missing env key skips
  # gracefully (keyless dev stays keyless). The whole leg runs inside a
  # secret-aware boundary: the key must never reach a log line, and a failure
  # must never fail the seed.
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
                  "credential wiring rather than risk changing credentials without a bounded " <>
                  "pre-read; the next boot's ensure/0 retries"
              )
          end

        _ ->
          Logger.warning(
            "hello official-site seed: #{@llm_api_key_env} not set — the official-site llm responder " <>
              "stays keyless (set it to wire the DeepSeek credential)"
          )
      end
    end)
  end

  # A read failure is NOT absence. `Kind.read/2` preserves the original bounded
  # live/cold read contract; only a successful read may authorize the CAS
  # dispatch. This keeps slow/unreadable agents on the skip path.
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
  defp credential_error_class(%{__exception__: true} = e), do: exception_class(e)
  defp credential_error_class({:error, reason}), do: credential_error_class(reason)
  defp credential_error_class({first, _}) when is_atom(first), do: Atom.to_string(first)
  defp credential_error_class({first, _, _}) when is_atom(first), do: Atom.to_string(first)
  defp credential_error_class(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp credential_error_class(_), do: "unknown"

  # The exception's module as a key-free class tag. The `%mod{}` struct
  # pattern binds `mod` directly (no dynamic `e.__struct__` field read on a
  # value the workspace-locality scanner cannot type-prove).
  defp exception_class(%mod{}), do: inspect(mod)

  # Delete every seed-owned row from the retired direct delivery workaround.
  # Mutations still pass through the Session routing ActionSet with one exact
  # target-issued cap; operator/template rules are not touched.
  defp remove_direct_delivery_rules(%URI{} = site_uri) do
    best_effort("retired official-site delivery-rule cleanup", fn ->
      table = Ezagent.Routing.Resolver.default_routing_table()
      matcher_json = Matcher.to_json(Matcher.in_session(site_uri))

      table
      |> RuleStore.list()
      |> Enum.filter(&owned_delivery_rule?(&1, matcher_json))
      |> Enum.each(&delete_delivery_rule(table, site_uri, &1))

      # Rehydrate after deletions so stale ETS delivery disappears this boot.
      :ok = RuleStore.load_into_registry(table)
    end)
  end

  # A row is OURS to reconcile when it carries the seed-owned rule_set
  # marker, or it is a legacy pre-marker row from this same workaround
  # (admin-attributed in_session rule for THIS session without a rule_set).
  # The legacy leg is what garbage-collects rows pointing at a removed llm
  # member — those would otherwise keep delivering to a dead agent.
  defp owned_delivery_rule?(
         %{rule_set: rule_set, matcher_data: matcher_data, created_by: created_by},
         matcher_json
       ) do
    admin_created_by = uri_to_string(User.admin_uri())

    rule_set == @delivery_rule_set or
      (is_nil(rule_set) and matcher_data == matcher_json and
         created_by == admin_created_by)
  end

  defp delete_delivery_rule(table, %URI{} = site_uri, %{id: id}) do
    case dispatch_rule_mutation(site_uri, :delete_rule, %{table: table, id: id}) do
      {:ok, %{deleted: _}} ->
        :ok

      {:error, reason} ->
        # A concurrent seeder may have deleted the same row first — benign.
        Logger.warning(
          "hello official-site seed: stale official-site delivery rule #{id} delete returned " <>
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
          exception_class(e)
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
