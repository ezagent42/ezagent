defmodule EzagentPluginHello.OfficialSiteSeed do
  @moduledoc """
  Governed, absence-gated provisioner for the official Hello session.

  The founder is an existing non-admin user selected by this deployment's
  seed configuration. This module never creates a user or falls back to a
  hard-coded principal.

  ## INTERIM responder wiring (removed by the #1667 structural fix)

  Beyond provisioning, `ensure/0` durably re-wires the live-prod WORKAROUND
  that keeps the 官网 answering after a reseed:

    1. the `llm` greeter member's DeepSeek credential, dispatched via
       `:put_api_key` from `DEEPSEEK_API_KEY` (absent env → skipped with a
       warning, never a crash, never a hardcoded key);
    2. a session-scoped `MentionRouting` delivery rule
       (`in_session(官网) → [llm agent]`) so every message in the session
       reaches the keyed responder directly.

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

  defp wire_responder(%URI{} = site_uri) do
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

    :ok
  end

  # (a) The DeepSeek credential on the llm greeter agent, mirroring the
  # live-prod `:put_api_key` dispatch. Absence-gated on the agent's api_keys
  # slice; a missing env key skips gracefully (keyless dev stays keyless).
  defp ensure_llm_credential(%URI{} = llm_uri) do
    case System.get_env(@llm_api_key_env) do
      key when is_binary(key) and key != "" ->
        if llm_key_present?(llm_uri) do
          :ok
        else
          put_llm_api_key(llm_uri, key)
        end

      _ ->
        Logger.warning(
          "hello official-site seed: #{@llm_api_key_env} not set — the 官网 llm responder " <>
            "stays keyless (set it to wire the DeepSeek credential)"
        )
    end
  end

  defp llm_key_present?(%URI{} = llm_uri) do
    case Ezagent.Kind.read(llm_uri, :api_keys) do
      {:ok, slice} when is_map(slice) ->
        slice
        |> Map.get(:keys, %{})
        |> Map.get(@llm_provider)
        |> case do
          key when is_binary(key) and key != "" -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  # The same dispatch shape the curl flavor's own credential cascade uses
  # (`Ezagent.PluginCurlAgent.Template.put_target_api_key/3`): an admin-issued
  # narrow `put_api_key` cap presented by the agent ITSELF (self-authority
  # over its own :api_keys slice).
  defp put_llm_api_key(%URI{} = llm_uri, key) do
    target = Ezagent.URI.with_action(llm_uri, :api_keys, :put_api_key)

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
            "#{URI.to_string(llm_uri)}: #{inspect(reason)}"
        )
    end
  end

  # (b) The session-scoped delivery rule: EVERY message in the 官网 session is
  # delivered directly to the (keyed) llm agent. Absence-gated on an existing
  # rule with the SAME matcher + receiver (re-running the seed never
  # duplicates). `source: "admin"` mirrors the live-prod rule exactly.
  defp ensure_delivery_rule(%URI{} = site_uri, %URI{} = llm_uri) do
    table = Ezagent.Routing.Resolver.default_routing_table()

    if delivery_rule_present?(table, site_uri, llm_uri) do
      :ok
    else
      case RuleStore.add(
             table,
             Matcher.in_session(site_uri),
             [llm_uri],
             User.admin_uri(),
             source: RuleStore.admin_source()
           ) do
        {:ok, _row} ->
          :ok = RuleStore.load_into_registry(table)
          :ok

        {:error, reason} ->
          Logger.warning(
            "hello official-site seed: failed to add the 官网 delivery rule: #{inspect(reason)}"
          )
      end
    end
  end

  defp delivery_rule_present?(table, %URI{} = site_uri, %URI{} = llm_uri) do
    matcher_json = Matcher.to_json(Matcher.in_session(site_uri))
    receiver = uri_to_string(llm_uri)

    table
    |> RuleStore.list()
    |> Enum.any?(fn rule ->
      rule.matcher_data == matcher_json and receiver in (rule.receivers || [])
    end)
  end

  # Off-the-receiver-line URI serializer (keeps the membership comparison
  # clear of the uri_query.scan `uri_string_key` heuristic — the repo's
  # `uri_to_string/1` convention; persisted rule receivers are strings).
  defp uri_to_string(%URI{} = uri), do: URI.to_string(uri)
end
