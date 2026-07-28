defmodule Ezagent.PluginCurlAgent.Template do
  @moduledoc """
  Template Class `curl.agent` — declares a CurlAgent instance in a
  Workspace.

  Form fields (auto-derived UI via `Ezagent.UI.Form`):

  - `agent_uri` — `entity://agent/team-alpha/curl_<name>` (PR #141 SPEC v2)
  - `provider` — `"deepseek"` / `"openai"` / ... (matches the key
    provider stored on THIS agent's own `api_keys` slice)
  - `api_url` — full URL of the OpenAI-compatible
    `/chat/completions` endpoint
  - `model` — provider-specific model id
  - `system_prompt` — optional textarea
  - `max_history` — int, default 20

  Allen 2026-05-26 — the `owner_uri` form field is gone (post
  ApiKeys-to-Agent flip). Keys live on the agent itself. The
  `creator_uri` arg passed to `instantiate/3` (the caller URI from
  the LV) populates the `:api_keys` slice `:creator_uri` so the
  creator + admin can rotate keys; no foreign user binding.

  ## On instantiate

  Spawns the CurlAgent Kind at `curl-agent://<name>` with the
  config as `init_slice` args. Idempotent against KindRegistry —
  re-instantiate skips if already alive.

  `instantiate/3` returns the 3-element `{:ok, [agent_uri],
  %{fresh?: boolean()}}` form (codex round-6 HIGH-1) — `fresh?` is
  `true` iff THIS call's `DynamicSupervisor.start_child` started the
  worker. The signal lets `update_agent_template`'s rollback-safe swap
  refuse adopting a worker another process created.

  ## What this template does NOT validate

  - Whether the owner User has a `provider` key set today —
    `:receive` will surface a chat-visible error at the first
    message if the key is missing. This matches the cc.pty
    pattern: instantiate-time validation only covers structural
    correctness; runtime errors are surfaced via the chat itself.
  """

  @behaviour Ezagent.Kind.Template
  @behaviour Ezagent.UI.Form
  @behaviour Ezagent.Agent.CredentialSliceAdapter

  require Logger

  alias Ezagent.Credential.GrantRow
  alias Ezagent.Invocation

  @impl Ezagent.Kind.Template
  def template_name, do: "curl.agent"

  @impl Ezagent.Agent.CredentialSliceAdapter
  def credential_slice, do: :api_keys

  @impl Ezagent.Agent.CredentialSliceAdapter
  def materialize_credential_slice(%URI{} = agent_uri, tmpl) when is_map(tmpl) do
    # #201-cred (codex r2 NEW-HIGH-3) — the behaviour callback carries NO
    # created-winner witness, so a pending grant here fail-closes at the mint.
    # The genuine created-winner path is `instantiate/3`, which threads the
    # witness from its `:started ∧ created?` receipt into
    # `materialize_credential_slice_with_receipt/3`.
    case materialize_credential_slice_with_receipt(agent_uri, tmpl, nil) do
      {:ok, _receipt} -> :ok
      {:error, _} = err -> err
    end
  end

  def materialize_credential_slice(_agent_uri, _tmpl),
    do: {:error, :invalid_curl_slice_materialize_args}

  @doc false
  # #201-cred (codex r2 HIGH-1/2/4) — the created-winner's slice
  # materialization WITH the deferred-mint receipt:
  #
  #   1. MINT the pending grant descriptor (authorized at domain resolution
  #      time) — the durable mint happens HERE, after the `:started ∧
  #      created?` receipt, never earlier;
  #   2. fetch the grant (returning its incarnation id), copy the secret,
  #      revalidate `(agent_uri, incarnation_id, version)` immediately before
  #      the slice write;
  #   3. on ANY post-mint failure, CONFIRM-compensate exactly the minted
  #      incarnation (a compensation failure surfaces COMPOSITE, never
  #      swallowed);
  #   4. on success return `{:ok, incarnation_id | nil}` — the instantiate
  #      arm threads the receipt into its meta for the chokepoint's rollback.
  #
  # #201-cred (codex r2 NEW-HIGH-3) — `witness` is the created-winner proof
  # (`Ezagent.Kind.CreatedWitness`) the `instantiate/3` arm captured from its
  # `:started ∧ created?` receipt; it is threaded to `GrantMint.mint/3`, which
  # refuses to mint without it.
  def materialize_credential_slice_with_receipt(%URI{} = agent_uri, tmpl, witness)
      when is_map(tmpl) do
    case selected_credential_source(tmpl) do
      :skip ->
        {:ok, nil}

      {:ok, selected_source} ->
        with {:ok, minted} <- mint_pending_grant(agent_uri, tmpl, witness) do
          # #201-cred (codex r2 NEW-HIGH-1) — `do_materialize_credential_slice/3`
          # returns `{:error, _}` on a clean failure, but a RAISE/THROW in the
          # post-mint region (grant fetch, source-slice read, the slice-write
          # dispatch) would skip `compensate_minted/3` and leak the just-minted
          # grant. CONFIRM-compensate the minted incarnation on ANY exception,
          # then re-raise the original so the spawn still aborts.
          try do
            case do_materialize_credential_slice(agent_uri, tmpl, selected_source) do
              {:ok, incarnation_id} ->
                {:ok, incarnation_id}

              {:error, reason} ->
                compensate_minted(agent_uri, minted, reason)
            end
          rescue
            exception ->
              Ezagent.Credential.GrantMint.reraise_compensating(
                URI.to_string(agent_uri),
                Ezagent.Credential.GrantMint.grant_incarnation(minted),
                exception,
                __STACKTRACE__
              )
          catch
            kind, reason ->
              Ezagent.Credential.GrantMint.raise_compensating(
                URI.to_string(agent_uri),
                Ezagent.Credential.GrantMint.grant_incarnation(minted),
                kind,
                reason,
                __STACKTRACE__
              )
          end
        end
    end
  end

  def materialize_credential_slice_with_receipt(_agent_uri, _tmpl, _witness),
    do: {:error, :invalid_curl_slice_materialize_args}

  defp do_materialize_credential_slice(agent_uri, tmpl, selected_source) do
    with {:ok, provider} <- selected_provider(tmpl),
         {:ok, granted_source, version, incarnation_id} <-
           GrantRow.fetch_for_materialize(URI.to_string(agent_uri)),
         :ok <- assert_grant_source(selected_source, granted_source),
         {:ok, key} <- source_api_key(selected_source, provider),
         :ok <- GrantRow.revalidate_version!(URI.to_string(agent_uri), incarnation_id, version),
         {:ok, _result} <- put_target_api_key(agent_uri, provider, key) do
      {:ok, incarnation_id}
    end
  end

  # The pending grant descriptor rides the `cascade_resolution` (authorized at
  # domain resolution time). Absent → nothing to mint (no credential source).
  # #201-cred (codex r2 NEW-HIGH-3) — the mint requires the created-winner
  # `witness`; `GrantMint.mint/3` fail-closes without it.
  defp mint_pending_grant(%URI{} = agent_uri, tmpl, witness) do
    case Map.get(tmpl, "cascade_resolution") || Map.get(tmpl, :cascade_resolution) do
      %{} = resolution ->
        case Map.get(resolution, "pending_grant") || Map.get(resolution, :pending_grant) do
          %{} = pending -> Ezagent.Credential.GrantMint.mint(agent_uri, pending, witness)
          _ -> {:ok, nil}
        end

      _ ->
        {:ok, nil}
    end
  end

  # Confirmed compensation of the minted incarnation on a post-mint failure.
  # A compensation failure is COMPOSITE — never collapse it into the primary
  # error (a silently leaked grant is a security-critical residue).
  defp compensate_minted(agent_uri, minted, reason) do
    case Ezagent.Credential.GrantMint.grant_incarnation(minted) do
      nil ->
        {:error, reason}

      incarnation_id ->
        case Ezagent.Credential.GrantMint.compensate(
               URI.to_string(agent_uri),
               incarnation_id
             ) do
          :ok -> {:error, reason}
          {:error, :grant_compensation_failed} -> {:error, {reason, :grant_compensation_failed}}
        end
    end
  end

  # SPEC 2026-06-01-flavor-generic-template-data (approach B): curl's
  # template_data fields, so an orchestrator-spawned curl worker LEARNS
  # its provider/api_url/model (pre-fix these were dropped by core's
  # cc-only mapping → nil → couldn't call the provider). provider/api_url/
  # model are required (validate/1 rejects empty); max_history is threaded
  # as-is (int or string) — instantiate/3 coerces via parse_int/2.
  @impl Ezagent.Kind.Template
  def template_data_extra(content) when is_map(content) do
    %{
      "provider" => content_field(content, :provider),
      "api_url" => content_field(content, :api_url),
      "model" => content_field(content, :model),
      "system_prompt" => content_field(content, :system_prompt),
      "max_history" => content_field(content, :max_history)
    }
  end

  def template_data_extra(_), do: %{}

  @impl Ezagent.Kind.Template
  def config_schema do
    [
      %{key: "provider", type: :string, label: "Provider", required: true},
      %{key: "api_url", type: :string, label: "API URL", required: true},
      %{
        key: "model",
        type: :string,
        label: "Model",
        required: true,
        placeholder: "deepseek-chat",
        help: "Provider model id, for example deepseek-chat"
      },
      %{key: "system_prompt", type: :text, label: "System prompt"},
      %{key: "max_history", type: :integer, label: "Max history", default: 20}
    ]
  end

  # Cleanup-2: shared tolerant content reader lives in core.
  defp content_field(content, key), do: Ezagent.Kind.Template.content_field(content, key)

  @impl Ezagent.Kind.Template
  def compile(resolved, params),
    do: Ezagent.Kind.Template.compile_curl_agent_data(resolved, params, &template_data_extra/1)

  @impl Ezagent.Kind.Template
  def validate(tmpl) when is_map(tmpl) do
    with :ok <- check_class(tmpl),
         :ok <- check_agent_uri(tmpl),
         :ok <- check_provider(tmpl),
         :ok <- check_api_url(tmpl),
         :ok <- check_model(tmpl),
         :ok <- check_optional_max_history(tmpl) do
      :ok
    end
  end

  def validate(_), do: {:error, :not_a_map}

  defp check_class(%{"class" => "curl.agent"}), do: :ok
  defp check_class(%{"class" => other}), do: {:error, {:wrong_class, other}}
  defp check_class(_), do: {:error, :missing_class_field}

  # Cleanup-2: shared entity-agent-URI validator lives in core
  # (Ezagent.Kind.Template) — byte-identical across every flavor.
  defp check_agent_uri(tmpl), do: Ezagent.Kind.Template.check_agent_uri(tmpl)

  defp check_provider(%{"provider" => p}) when is_binary(p) and p != "", do: :ok
  defp check_provider(_), do: {:error, :missing_provider}

  defp check_api_url(%{"api_url" => u}) when is_binary(u) and u != "" do
    if String.starts_with?(u, "http://") or String.starts_with?(u, "https://") do
      :ok
    else
      {:error, {:bad_api_url, u}}
    end
  end

  defp check_api_url(_), do: {:error, :missing_api_url}

  defp check_model(%{"model" => m}) when is_binary(m) and m != "", do: :ok
  defp check_model(_), do: {:error, :missing_model}

  defp check_optional_max_history(tmpl) do
    case Map.fetch(tmpl, "max_history") do
      :error -> :ok
      {:ok, n} when is_integer(n) and n > 0 -> :ok
      {:ok, s} when is_binary(s) -> check_max_history_string(s)
      {:ok, bad} -> {:error, {:bad_max_history, bad}}
    end
  end

  defp check_max_history_string(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> :ok
      _ -> {:error, {:bad_max_history, s}}
    end
  end

  @impl Ezagent.Kind.Template
  def instantiate(_tmpl_name, %{"agent_uri" => agent_uri_str} = tmpl, _workspace_uri) do
    instantiate_with_opts(agent_uri_str, tmpl, [])
  end

  def instantiate(_tmpl_name, tmpl, _workspace_uri), do: {:error, {:invalid_template, tmpl}}

  @impl Ezagent.Kind.Template
  def instantiate(_tmpl_name, %{"agent_uri" => agent_uri_str} = tmpl, _workspace_uri,
        launch_context: launch_context
      ) do
    instantiate_with_opts(agent_uri_str, tmpl, launch_context: launch_context)
  end

  def instantiate(_tmpl_name, _tmpl, _workspace_uri, _opts), do: {:error, :invalid_launch_options}

  defp instantiate_with_opts(agent_uri_str, tmpl, opts) do
    agent_uri = Ezagent.URI.new!(agent_uri_str)

    init_args = %{
      uri: agent_uri,
      # PR-6 (im/session/agent decomposition §3.5) — a NEW curl agent spawns
      # on the UNIFIED `Ezagent.Entity.Agent` Kind. The curl flavor's STATE
      # behavior (`Behavior.CurlAgent`) is selected via the explicit
      # per-instance `:behaviors` set (the same `:kind_base` mechanism the
      # Session Kind uses); the set persists, so cold-load rehydrates it.
      behaviors: Ezagent.Entity.Agent.curl_behaviors(),
      provider: tmpl["provider"],
      api_url: tmpl["api_url"],
      model: tmpl["model"],
      system_prompt: nil_if_empty(tmpl["system_prompt"]),
      max_history: parse_int(tmpl["max_history"], 20)
      # Allen 2026-05-26 — `owner_uri` removed; keys live on this agent's
      # own `:api_keys` slice. `creator_uri` for the slice is left nil
      # in this template path (the LV/CLI direct-spawn path doesn't
      # thread caller_uri through SpawnRegistry today — admin retains
      # wildcard cap regardless; non-admin creator-grant wiring is
      # future work tracked in docs/futures/todo.md).
    }

    # PR-6 — record the stored `curl` flavor attribute (O-2: flavor is a
    # STORED slice field, read at load via `Ezagent.UriQuery`, NOT a
    # name-segment prefix). `AgentBridge.deliver` + the AgentModuleResolver
    # resolve the agent's flavor through this, picking the curl
    # `:in_process_sync` adapter + the unified Kind module.
    :ok = Ezagent.AgentFlavorAttributes.put(agent_uri, "curl")

    # V1 prevention (Allen 2026-05-21): route via Ezagent.Kind.spawn/2.
    # PR-6+7 — the curl flavor spawns the unified `Ezagent.Entity.Agent`
    # Kind (the standalone curl Kind is deleted); the Agent Kind's
    # `supervisor/0` is `EzagentDomainInstanceMessage.AgentSupervisor`.
    #
    # codex round-6 HIGH-1 — `Ezagent.Kind.spawn/2` returns the raw
    # `DynamicSupervisor.start_child` outcome, which atomically
    # distinguishes `{:ok, pid}` (THIS call started the worker) from
    # `{:error, {:already_started, pid}}` (it pre-existed). Thread that
    # ground truth out as `%{fresh?: _}` so `update_agent_template`'s
    # swap can refuse adopting a worker it did not create.
    #
    # #201 PR-3 — the spawn receipt ALSO carries the core logical-create
    # verdict (`created?`). The `:api_keys` slice materialization is a
    # create-only credential write: it runs ONLY on `:started ∧ created?`
    # (a genuine first-ever create). A rehydrating winner
    # (`:started ∧ ¬created?`) and an adopt (`:already_started`) write
    # NOTHING into the live agent's slice (the adopt arm previously
    # re-wrote THIS attempt's key into the adopted agent — a clobber).
    # derivation-edge: template-post-obligation TemplateSpawn records fresh workers
    case Ezagent.Kind.spawn_receipt(Ezagent.Entity.Agent, init_args, opts) do
      {:ok, :started, _pid, %{created?: true} = receipt} ->
        # #201-cred (codex r2 NEW-HIGH-3) — thread the created-winner witness
        # from THIS `:started ∧ created?` receipt into the slice mint.
        case materialize_credential_slice_with_receipt(
               agent_uri,
               tmpl,
               Map.get(receipt, :created_witness)
             ) do
          {:ok, grant_incarnation_id} ->
            {:ok, [agent_uri],
             %{
               fresh?: true,
               created?: true,
               # #201-cred — the deferred-mint receipt for the chokepoint's
               # rollback (nil = no grant minted).
               grant_incarnation_id: grant_incarnation_id
             }}

          {:error, reason} ->
            Ezagent.Kind.terminate!(agent_uri)
            {:error, reason}
        end

      {:ok, :started, _pid, %{created?: false}} ->
        {:ok, [agent_uri], %{fresh?: true, created?: false}}

      {:ok, :already_started, _pid, _receipt} ->
        {:ok, [agent_uri], %{fresh?: false}}

      {:error, reason} ->
        Logger.warning(
          "curl.agent Template instantiate failed for #{URI.to_string(agent_uri)}: " <>
            inspect(reason)
        )

        {:error, reason}
    end
  end

  defp selected_credential_source(tmpl) do
    case Map.get(tmpl, "cascade_resolution") || Map.get(tmpl, :cascade_resolution) do
      %{} = resolution ->
        case Map.get(resolution, "credential_source_uri") ||
               Map.get(resolution, :credential_source_uri) do
          %URI{} = source ->
            {:ok, source}

          source when is_binary(source) and source != "" ->
            {:ok, Ezagent.URI.new!(source)}

          _ ->
            :skip
        end

      _ ->
        :skip
    end
  end

  defp selected_provider(tmpl) do
    case Map.get(tmpl, "provider") || Map.get(tmpl, :provider) do
      provider when is_binary(provider) and provider != "" -> {:ok, provider}
      _ -> {:error, :missing_provider}
    end
  end

  defp assert_grant_source(%URI{} = selected, granted_source) when is_binary(granted_source) do
    if URI.to_string(selected) == granted_source do
      :ok
    else
      {:error, {:credential_grant_source_mismatch, selected, granted_source}}
    end
  end

  defp source_api_key(%URI{} = source, provider) do
    with {:ok, slice} <- source_api_keys_slice(source),
         {:ok, key} <- fetch_provider_key(source, slice, provider) do
      {:ok, key}
    end
  end

  # Read the credential source's `:api_keys` slice via the §2.2 public read
  # surface, in its sanctioned live-preferred compose (§2.2): live slice via
  # `read/3` (`spawn: :never`), falling back to `read_durable/3` — the durable
  # snapshot-row projection — when the source is cold. NEVER spawns the source
  # (its snapshot can predate the current rehydration loader — a spawn would
  # fail `:snapshot_version_too_new` where a durable decode succeeds).
  defp source_api_keys_slice(%URI{} = source) do
    case Ezagent.Kind.read(source, :api_keys, spawn: :never) do
      {:ok, slice} when is_map(slice) ->
        {:ok, slice}

      _ ->
        case Ezagent.Kind.read_durable(source, :api_keys) do
          {:ok, slice, _meta} when is_map(slice) ->
            {:ok, slice}

          {:ok, _non_map, _meta} ->
            {:error, {:cascade_api_keys_slice_missing, source}}

          {:error, reason} ->
            {:error, {:cascade_source_snapshot_missing, source, reason}}
        end
    end
  end

  defp fetch_provider_key(%URI{} = source, slice, provider) do
    keys = Map.get(slice, :keys, %{})

    case Map.fetch(keys, provider) do
      {:ok, key} when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, {:cascade_api_key_missing, provider, source}}
    end
  end

  defp put_target_api_key(%URI{} = agent_uri, provider, key) do
    target = Ezagent.URI.with_action(agent_uri, :api_keys, :put_api_key)

    with {:ok, cap} <-
           Ezagent.Cap.issue_for_action(
             {:admin, Ezagent.Entity.User.admin_uri()},
             agent_uri,
             target
           ) do
      Invocation.dispatch(%Invocation{
        target: target,
        mode: :call,
        args: %{provider: provider, key: key},
        ctx: %{
          caller: agent_uri,
          authenticated_principal: agent_uri,
          caps: [cap],
          reply: {:caller_inbox, self()}
        },
        origin: :trusted_internal
      })
    end
  end

  defp nil_if_empty(nil), do: nil
  defp nil_if_empty(""), do: nil
  defp nil_if_empty(s) when is_binary(s), do: s

  defp parse_int(nil, default), do: default
  defp parse_int(n, _) when is_integer(n) and n > 0, do: n

  defp parse_int(s, default) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  defp parse_int(_, default), do: default

  # --- Ezagent.UI.Form ---------------------------------------------------

  @impl Ezagent.UI.Form
  def form_fields do
    [
      %{
        name: "agent_uri",
        type: :uri,
        label: "Agent URI",
        required: true,
        placeholder: "curl_my-deepseek"
      },
      %{
        name: "provider",
        type: :text,
        label: "Provider (selects which api_keys entry to use)",
        required: true,
        placeholder: "deepseek"
      },
      %{
        name: "api_url",
        type: :text,
        label: "API URL (OpenAI-compatible /chat/completions endpoint)",
        required: true,
        placeholder: "https://api.deepseek.com/chat/completions"
      },
      %{
        name: "model",
        type: :text,
        label: "Model",
        required: true,
        placeholder: "deepseek-chat"
      },
      %{
        name: "system_prompt",
        type: :text,
        label: "System prompt (optional)",
        required: false,
        placeholder: "You are a concise, helpful assistant."
      },
      %{
        name: "max_history",
        type: :text,
        label: "Max history turns",
        required: false,
        placeholder: "20"
      }
      # Allen 2026-05-26 — the `owner_uri` form field is gone. Keys
      # live on the agent itself (Behavior.ApiKeys moved to Agent
      # Kind); there's no foreign user to bind to.
    ]
  end
end
