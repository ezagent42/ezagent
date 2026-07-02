defmodule Ezagent.ActionSet.Workspace.Members do
  @moduledoc false

  @spec read_members(map()) :: MapSet.t()
  def read_members(args) do
    case Map.get(args, :members) do
      nil -> MapSet.new()
      %MapSet{} = set -> set
      list when is_list(list) -> MapSet.new(list)
    end
  end

  # Task #55 — workspace prefix validator. Confirms the member URI's
  # workspace segment matches the workspace URI's host. Member URIs are
  # identities, so query/fragment-bearing entity URIs are rejected before
  # canonical instance comparison.
  @spec validate_member_prefix(URI.t(), URI.t() | nil) ::
          :ok
          | {:error,
             {:bad_member_uri, URI.t()}
             | {:non_entity_member, URI.t(), URI.t()}
             | {:cross_workspace_member_not_permitted, URI.t(), URI.t()}}
  def validate_member_prefix(_member_uri, nil), do: :ok

  def validate_member_prefix(
        %URI{scheme: "entity"} = member_uri,
        %URI{scheme: "workspace"} = workspace_uri
      ) do
    workspace_name = Ezagent.URI.name!(workspace_uri)

    cond do
      member_uri.query != nil ->
        {:error, {:bad_member_uri, member_uri}}

      member_uri.fragment != nil ->
        {:error, {:bad_member_uri, member_uri}}

      true ->
        validate_member_prefix_canonical(member_uri, workspace_uri, workspace_name)
    end
  end

  def validate_member_prefix(%URI{} = member_uri, %URI{} = workspace_uri) do
    {:error, {:non_entity_member, member_uri, workspace_uri}}
  end

  defp validate_member_prefix_canonical(member_uri, workspace_uri, workspace_name) do
    with {:ok, canonical} <- canonicalize_entity_uri(member_uri),
         {:ok, type_axis} <- Ezagent.URI.type(canonical),
         true <- type_axis in ["user", "agent"] or {:bad_host, type_axis} do
      case {Ezagent.URI.workspace_name(canonical), Ezagent.URI.name(canonical)} do
        {{:ok, ^workspace_name}, {:ok, _entity_name}} ->
          :ok

        {{:ok, _other_workspace}, {:ok, _entity_name}} ->
          {:error, {:cross_workspace_member_not_permitted, member_uri, workspace_uri}}

        _ ->
          {:error, {:bad_member_uri, member_uri}}
      end
    else
      {:bad_host, _type_axis} ->
        {:error, {:bad_member_uri, member_uri}}

      {:error, _} = err ->
        err
    end
  end

  defp canonicalize_entity_uri(%URI{} = member_uri) do
    canonical =
      member_uri
      |> URI.to_string()
      |> Ezagent.URI.new!()
      |> Ezagent.URI.instance()

    {:ok, canonical}
  rescue
    ArgumentError ->
      {:error, {:bad_member_uri, member_uri}}
  end

  # Only user URIs are pre-spawned. Agents are lifecycle-owned elsewhere, and
  # unit tests without a registered entity spawn function keep the legacy :ok
  # tolerance for direct handler calls.
  @spec ensure_member_kind_spawned(URI.t() | term()) ::
          :ok | {:error, {:member_user_spawn_failed, URI.t(), term()}}
  def ensure_member_kind_spawned(%URI{scheme: "entity"} = uri) do
    if Ezagent.URI.type?(uri, :user) do
      case Ezagent.SpawnRegistry.spawn(uri) do
        {:ok, _pid} ->
          :ok

        {:error, {:no_spawn_fn, _scheme}} ->
          :ok

        {:error, reason} ->
          {:error, {:member_user_spawn_failed, uri, reason}}
      end
    else
      :ok
    end
  end

  def ensure_member_kind_spawned(_other), do: :ok

  @spec cross_prefix_violator?(URI.t() | term(), String.t()) :: boolean()
  def cross_prefix_violator?(%URI{} = member_uri, workspace_name) do
    case validate_member_prefix(
           member_uri,
           Ezagent.URI.workspace(workspace_name)
         ) do
      :ok -> false
      {:error, _} -> true
    end
  end

  def cross_prefix_violator?(_, _), do: true
end
