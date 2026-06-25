defmodule Ezagent.AgentFlavorResolver do
  @moduledoc """
  Deadlock-safe agent-flavor resolution shared by the session domain's
  `:flavor` UriQuery resolver and the agent domain's delivery seam
  (`Ezagent.Behavior.Agent.Delivery`).

  Lives in `ezagent_domain_agent` so both the session and agent domains reach the
  flavor cluster through the agent domain. Reads only ETS
  (`AgentFlavorAttributes` / `AgentFlavorRegistry`) and `SnapshotStore` (a DB
  read) — never `Kind.get_slice/2` — so it is safe to call from inside an
  agent's OWN dispatch process (delivery), where a self-`call` would deadlock.
  """

  @doc """
  Durable-snapshot flavor fallback (codex P2 — PR-6). Scans the persisted
  snapshot for ANY slice carrying a stored `:flavor`, so it stays flavor-blind.

  A flavor Behavior that owns DURABLE state persists its `:flavor` in its OWN
  slice (curl → the `:curl_agent` slice). After a BEAM restart / lazy
  demand-spawn the ETS `AgentFlavorAttributes` fast-path is gone AND the live
  sandbox carries no `template_class`/`respawn_template_data` (curl's
  `:in_process_sync` flavor never populates them), so both fast paths miss and
  the canonical resolver would return `:none` for a cold-loaded curl agent —
  mis-resolving every caller (`AgentBridge.resolve_flavor`, credential-source
  validation, flavor-aware UI), not just delivery. cc/codex carry no durable
  `:flavor` slice field, so they never match here and correctly resolve via the
  sandbox path.
  """
  @spec flavor_from_durable_snapshot(URI.t()) :: Ezagent.UriQuery.result()
  def flavor_from_durable_snapshot(%URI{} = uri) do
    case Ezagent.SnapshotStore.latest(uri) do
      {:ok, %{state: state}} when is_map(state) ->
        state
        |> Map.values()
        |> Enum.find_value(:none, fn
          slice when is_map(slice) ->
            case slice |> Ezagent.Kind.normalize_slice_view() |> Map.get(:flavor) do
              flavor when is_binary(flavor) and flavor != "" -> {:ok, flavor}
              _ -> nil
            end

          _ ->
            nil
        end)

      _ ->
        :none
    end
  rescue
    error in [DBConnection.ConnectionError, DBConnection.OwnershipError] ->
      require Logger

      Logger.warning(
        "AgentFlavorResolver: durable snapshot flavor lookup failed for #{URI.to_string(uri)}: " <>
          inspect(error.__struct__)
      )

      :none
  end

  @doc """
  Resolve an agent's flavor from its `:sandbox` slice (the launch-attribute
  path): a `respawn_template_data` `:flavor`/class, else a registered
  `template_class`. Returns `{:ok, flavor}` / `:none`.
  """
  @spec resolve_flavor_from_sandbox(term()) :: Ezagent.UriQuery.result()
  def resolve_flavor_from_sandbox(sandbox) when is_map(sandbox) do
    template_class = Map.get(sandbox, :template_class)
    respawn_template_data = Map.get(sandbox, :respawn_template_data)

    cond do
      is_map(respawn_template_data) ->
        flavor_from_respawn_data(respawn_template_data)

      is_atom(template_class) and template_class != nil ->
        flavor_from_template_class(template_class)

      true ->
        :none
    end
  end

  def resolve_flavor_from_sandbox(_), do: :none

  defp flavor_from_template_class(template_class) do
    case Enum.find(Ezagent.AgentFlavorRegistry.list_all(), fn
           {_flavor, %{template_class: registered}} -> registered == template_class
           _ -> false
         end) do
      {flavor, _decl} -> {:ok, flavor}
      nil -> :none
    end
  end

  defp flavor_from_respawn_data(data) when is_map(data) do
    case Map.get(data, :flavor) || Map.get(data, "flavor") do
      flavor when is_binary(flavor) and flavor != "" ->
        {:ok, flavor}

      _ ->
        data
        |> class_name_from_respawn_data()
        |> flavor_from_class_name()
    end
  end

  defp flavor_from_class_name(nil), do: :none

  defp flavor_from_class_name(class_name) when is_binary(class_name) do
    case Enum.find(Ezagent.AgentFlavorRegistry.list_all(), fn
           {_flavor, %{template_class: template_class}} ->
             template_name(template_class) == class_name

           _ ->
             false
         end) do
      {flavor, _decl} -> {:ok, flavor}
      nil -> :none
    end
  end

  defp class_name_from_respawn_data(data) when is_map(data) do
    Map.get(data, :class) || Map.get(data, "class")
  end

  defp template_name(template_class) when is_atom(template_class) do
    template_class.template_name()
  rescue
    _ -> nil
  end
end
