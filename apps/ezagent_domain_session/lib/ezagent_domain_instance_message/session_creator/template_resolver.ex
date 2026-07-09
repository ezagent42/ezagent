defmodule EzagentDomainInstanceMessage.SessionCreator.TemplateResolver do
  @moduledoc false

  alias Ezagent.Entity.Session
  alias Ezagent.Entity.SessionTemplate
  alias Ezagent.KindRegistry
  alias Ezagent.Socialware.DefinitionEditor
  alias Ezagent.TemplateTags

  # PR-9 A2 (2026-06-14): `resolve_template_class/1` RELOCATED to
  # `Ezagent.Entity.AgentTemplate` (the agent domain) so agent-domain callers
  # (AgentTemplate + its TemplateSpawn) no longer reach into this session-domain
  # module to resolve their own flavor → Template Class. Cuts an agent→session
  # compile edge for the PR-9 split. `resolve_agent_template_class/1` (URI-based)
  # stays here — it is used session-side.

  @spec resolve_agent_template_class(URI.t()) :: {:ok, module()} | {:error, term()}
  def resolve_agent_template_class(%URI{} = agent_uri) do
    case Ezagent.UriQuery.resolve(:flavor, agent_uri) do
      {:ok, flavor} when is_binary(flavor) and flavor != "" ->
        case Ezagent.AgentFlavorRegistry.lookup(flavor) do
          {:ok, %{template_class: tc}} -> {:ok, tc}
          :error -> {:error, :unknown_flavor}
        end

      :none ->
        {:error, :unknown_flavor}

      {:ok, _other} ->
        {:error, :bad_agent_flavor}

      {:error, reason} ->
        {:error, {:flavor_lookup_failed, reason}}
    end
  end

  def resolve_agent_template_class(_), do: {:error, :bad_agent_uri}

  @spec require_template_name!(keyword()) :: String.t()
  def require_template_name!(opts) do
    case Keyword.fetch(opts, :template_name) do
      {:ok, name} when is_binary(name) and name != "" ->
        name

      {:ok, other} ->
        raise ArgumentError,
              "EzagentDomainInstanceMessage.SessionCreator.create_session/3 requires opts[:template_name] to be " <>
                "a non-empty String, got: #{inspect(other)}. Per SPEC #366 the silent " <>
                "`\"default\"` fallback was removed; pick a class explicitly from the " <>
                "workspace's `session_templates` map (or use `\"default\"` literally " <>
                "for the bootstrap session-naming convention)."

      :error ->
        raise ArgumentError,
              "EzagentDomainInstanceMessage.SessionCreator.create_session/3 requires opts[:template_name] " <>
                "(SPEC #366, Allen 2026-05-26). The previous silent `\"default\"` " <>
                "fallback was removed. Callers — LV forms, CLI tasks, test seeds, " <>
                "bootstrap — must choose a template class explicitly. Examples:\n" <>
                "  * Bootstrap / preserve existing URI shape: `template_name: \"default\"`\n" <>
                "  * Tenant flows: `template_name: <key from workspace.session_templates>`\n" <>
                "Got: opts=#{inspect(opts)}."
    end
  end

  @spec resolve_for_repair(URI.t(), String.t(), URI.t()) ::
          {:ok, URI.t(), map()} | {:error, term()}
  def resolve_for_repair(%URI{} = session_uri, template_name, %URI{} = workspace_uri) do
    wc = Session.read_template_working_copy(session_uri)

    case Map.get(wc, :session_template_uri) do
      %URI{} = recorded ->
        with {:ok, _pid} <- Session.ensure_template_alive(recorded),
             {:ok, content} <- Session.read_template_content(recorded) do
          {:ok, recorded, content}
        else
          _ -> resolve_session_template!(template_name, workspace_uri)
        end

      _ ->
        resolve_session_template!(template_name, workspace_uri)
    end
  end

  @spec resolve_session_template!(String.t(), URI.t()) :: {:ok, URI.t(), map()} | {:error, term()}
  def resolve_session_template!(template_name, %URI{} = workspace_uri)
      when is_binary(template_name) do
    workspace_name = workspace_name_of!(workspace_uri)

    case find_session_template_uri(template_name, workspace_uri, workspace_name) do
      {:ok, %URI{} = session_template_uri} ->
        with {:ok, _pid} <- Session.ensure_template_alive(session_template_uri),
             {:ok, content} <- Session.read_template_content(session_template_uri) do
          {:ok, session_template_uri, content}
        else
          {:error, reason} ->
            {:error, {:session_template_not_readable, template_name, reason}}
        end

      :error when template_name == "default" ->
        ensure_and_resolve_default_session_template(template_name, workspace_uri, workspace_name)

      :error ->
        {:error, {:session_template_not_found, template_name, workspace_name}}
    end
  end

  @spec orchestrator_template_uri_of(map()) :: URI.t() | nil
  def orchestrator_template_uri_of(template_content) when is_map(template_content) do
    case Map.get(template_content, :orchestrator_template_uri) ||
           Map.get(template_content, "orchestrator_template_uri") do
      %URI{} = uri ->
        uri

      uri_str when is_binary(uri_str) and uri_str != "" ->
        Ezagent.URI.new!(uri_str)

      _ ->
        nil
    end
  end

  @spec orchestrator_template_uri_of(map(), URI.t() | String.t()) :: URI.t() | nil
  def orchestrator_template_uri_of(template_content, workspace_uri)
      when is_map(template_content) do
    case DefinitionEditor.orchestrator_template_uri_for_template(template_content, workspace_uri) do
      {:ok, %URI{} = uri} -> uri
      _ -> orchestrator_template_uri_of(template_content)
    end
  end

  defp ensure_and_resolve_default_session_template(
         template_name,
         %URI{} = workspace_uri,
         workspace_name
       ) do
    case EzagentDomainInstanceMessage.Application.ensure_default_session_template(workspace_uri) do
      :ok ->
        case find_session_template_uri(template_name, workspace_uri, workspace_name) do
          {:ok, %URI{} = session_template_uri} ->
            with {:ok, _pid} <- Session.ensure_template_alive(session_template_uri),
                 {:ok, content} <- Session.read_template_content(session_template_uri) do
              {:ok, session_template_uri, content}
            else
              {:error, reason} ->
                {:error, {:session_template_not_readable, template_name, reason}}
            end

          :error ->
            {:error, {:session_template_not_found, template_name, workspace_name}}
        end

      {:error, reason} ->
        {:error, {:session_template_seed_failed, template_name, workspace_name, reason}}
    end
  end

  defp find_session_template_uri(template_name, %URI{} = workspace_uri, workspace_name) do
    case TemplateTags.resolve(workspace_uri, template_name, "current") do
      {:ok, version_hash} ->
        {:ok, SessionTemplate.build_uri(template_name, version_hash, workspace: workspace_name)}

      :error ->
        find_session_template_uri_by_scan(template_name, workspace_name)
    end
  end

  # DETERMINISTIC name→URI resolution (fix/template-name-resolution).
  #
  # SessionTemplate versions are content-addressed: when new code ships a
  # new `default` version, BOTH `default@<hashA>` and `default@<hashB>`
  # coexist in storage. The old scan used `Enum.find_value` — FIRST MATCH,
  # UNORDERED — over the live `KindRegistry` (whose select order is
  # effectively arbitrary), so `create_session("default")` could resolve
  # the STALE version by luck. This resolves the NEWEST version instead.
  #
  # Recency signal = the `kind_snapshots` row's `inserted_at` (the version's
  # BIRTH time). A content-addressed version is write-once, and
  # `KindSnapshot.upsert/6` preserves `inserted_at` on conflict while only
  # bumping `updated_at` — so `inserted_at` is the STABLE per-version age,
  # whereas `updated_at` churns on every idempotent re-persist. Rank by
  # `inserted_at`, NOT `updated_at`. (Do not "simplify" this back to
  # `updated_at` — that reintroduces the order-dependence this fixes.)
  defp find_session_template_uri_by_scan(template_name, workspace_name) do
    prefix =
      workspace_name
      |> Ezagent.URI.template(:session, "#{template_name}@")
      |> URI.to_string()

    # uri_str => inserted_at (µs unix) for every persisted version of this
    # name. Both coexisting versions live here — this is the durable SoT.
    birth_by_uri = snapshot_birth_times(prefix)

    # Candidate set = union of live-registry URIs and snapshotted URIs, so
    # the (unordered) registry can never bias the pick: EVERY candidate is
    # ranked by its snapshot birth time. A live-but-unsnapshotted version
    # (transient; `clear_live_template_without_snapshot/1` normally reaps
    # it) ranks below any snapshotted version and is chosen only when no
    # snapshotted candidate exists.
    live_uris =
      KindRegistry.list_all()
      |> Enum.filter(fn {uri_str, _pid} ->
        is_binary(uri_str) and String.starts_with?(uri_str, prefix)
      end)
      |> Enum.map(fn {uri_str, _pid} -> uri_str end)

    candidates = Enum.uniq(Map.keys(birth_by_uri) ++ live_uris)

    case candidates do
      [] ->
        :error

      _ ->
        newest =
          Enum.max_by(candidates, fn uri_str ->
            case Map.get(birth_by_uri, uri_str) do
              # {1, ...} ranks snapshotted candidates above live-only ones;
              # `uri_str` is the deterministic tie-break for equal births.
              nil -> {0, 0, uri_str}
              birth_us -> {1, birth_us, uri_str}
            end
          end)

        {:ok, Ezagent.URI.new!(newest)}
    end
  end

  defp snapshot_birth_times(prefix) do
    Ezagent.Ecto.KindSnapshot.list_all()
    |> Enum.reduce(%{}, fn
      %{uri: uri_str, inserted_at: inserted_at}, acc when is_binary(uri_str) ->
        if String.starts_with?(uri_str, prefix) do
          Map.put(acc, uri_str, birth_us(inserted_at))
        else
          acc
        end

      _, acc ->
        acc
    end)
  rescue
    _ -> %{}
  end

  defp birth_us(%DateTime{} = dt), do: DateTime.to_unix(dt, :microsecond)
  defp birth_us(_), do: 0

  defp workspace_name_of!(%URI{scheme: "workspace"} = uri), do: Ezagent.URI.name!(uri)

  defp workspace_name_of!(other),
    do: raise(ArgumentError, "expected %URI{scheme: \"workspace\"}, got: #{inspect(other)}")
end
