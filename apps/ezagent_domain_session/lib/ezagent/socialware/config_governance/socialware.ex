defmodule Ezagent.Socialware.ConfigGovernance.Socialware do
  @moduledoc """
  Socialware-specific ConfigChangeStore governance.

  Socialware definitions are ConfigStore subjects (`socialware:<name>`), not
  live Kinds. This module is therefore a thin function boundary over the shared
  CR lifecycle engine, with the socialware-specific CapBAC subject, owner
  workspace binding, and public-listing admin gate.
  """

  alias Ezagent.Socialware.{ConfigChangeStore, Definition, DefinitionRegistry}

  @layer :workspace
  @key DefinitionRegistry.definition_key()

  @type ctx :: %{
          required(:caller) => URI.t(),
          required(:workspace_uri) => URI.t() | String.t(),
          required(:caps) => Enumerable.t()
        }

  @doc "Build the socialware manage cap for a definition name in a workspace."
  @spec manage_cap(String.t(), URI.t() | String.t(), URI.t()) :: Ezagent.Capability.t()
  def manage_cap(name, workspace_uri, granted_by)
      when is_binary(name) and is_binary(name) and name != "" do
    %Ezagent.Capability{
      Ezagent.Capability.cap(
        :socialware,
        :manage,
        :any,
        subject(name),
        workspace_uri_struct(workspace_uri)
      )
      | granted_by: granted_by,
        granted_at: DateTime.utc_now()
    }
  end

  @doc "Open a CR for a socialware definition subject."
  @spec open_cr(map(), ctx()) :: {:ok, map()} | {:error, term()}
  def open_cr(%{name: name}, ctx) when is_binary(name) and name != "" do
    with :ok <- authorize_manage(name, ctx),
         {:ok, cr} <-
           ConfigChangeStore.open(%{
             workspace_uri: workspace_uri(ctx),
             subject_uri: subject(name),
             opened_by: Map.fetch!(ctx, :caller),
             title: Map.get(ctx, :title),
             note: Map.get(ctx, :note)
           }) do
      {:ok, %{cr_id: cr.id, status: cr.status}}
    end
  end

  def open_cr(_args, _ctx), do: {:error, :invalid_socialware_cr_open}

  @doc "Stage a full socialware definition body under an open CR."
  @spec stage_definition(String.t(), Definition.t() | map(), ctx()) ::
          {:ok, map()} | {:error, term()}
  def stage_definition(cr_id, definition_or_attrs, ctx) when is_binary(cr_id) do
    with {:ok, cr} <- fetch_cr(cr_id),
         {:ok, name} <- subject_name(cr.subject_uri),
         :ok <- authorize_manage(name, ctx),
         :ok <- assert_workspace(cr, ctx),
         {:ok, %Definition{} = definition} <- normalize_definition(definition_or_attrs),
         :ok <- assert_definition_subject(definition, name),
         {:ok, item} <-
           ConfigChangeStore.stage_item(%{
             change_request_id: cr_id,
             layer: @layer,
             key: @key,
             replace_body: Definition.body(definition),
             actor_uri: Map.fetch!(ctx, :caller)
           }) do
      {:ok, %{item_id: item.id, staged_object_id: item.staged_object_id}}
    end
  end

  @doc "Publish a socialware CR after manage authorization and public-scope moderation gate."
  @spec publish_cr(String.t(), ctx()) :: {:ok, map()} | {:error, term()}
  def publish_cr(cr_id, ctx) when is_binary(cr_id) do
    with {:ok, cr} <- fetch_cr(cr_id),
         {:ok, name} <- subject_name(cr.subject_uri),
         :ok <- authorize_manage(name, ctx),
         :ok <- assert_workspace(cr, ctx),
         :ok <- authorize_public_scope(cr_id, ctx),
         {:ok, %{cr: published}} <-
           ConfigChangeStore.publish(%{
             change_request_id: cr_id,
             published_by: Map.fetch!(ctx, :caller)
           }) do
      {:ok,
       %{
         cr_id: published.id,
         status: published.status,
         published_turn_id: published.published_turn_id
       }}
    end
  end

  @doc "Reject an open socialware CR."
  @spec reject_cr(String.t(), ctx()) :: {:ok, map()} | {:error, term()}
  def reject_cr(cr_id, ctx) when is_binary(cr_id) do
    with {:ok, cr} <- fetch_cr(cr_id),
         {:ok, name} <- subject_name(cr.subject_uri),
         :ok <- authorize_manage(name, ctx),
         :ok <- assert_workspace(cr, ctx),
         {:ok, rejected} <- ConfigChangeStore.reject(cr_id) do
      {:ok, %{cr_id: rejected.id, status: rejected.status}}
    end
  end

  defp authorize_public_scope(cr_id, ctx) do
    with {:ok, diffs} <- ConfigChangeStore.preview(cr_id) do
      if Enum.any?(diffs, &public_definition?/1) do
        authorize_admin(ctx)
      else
        :ok
      end
    end
  end

  defp public_definition?(%{key: @key, proposed_body: body}) when is_map(body) do
    case Definition.new(body) do
      {:ok, %Definition{visibility_policy: %{scope: :public}}} -> true
      _ -> false
    end
  end

  defp public_definition?(_), do: false

  defp authorize_manage(name, ctx) do
    needed = %{
      kind: :socialware,
      behavior: :manage,
      action: :any,
      instance: subject(name),
      workspace_uri: workspace_uri_struct(Map.fetch!(ctx, :workspace_uri))
    }

    if authorized?(ctx, needed), do: :ok, else: {:error, :unauthorized}
  end

  defp authorize_admin(ctx) do
    caller = Map.fetch!(ctx, :caller)
    caps = Map.get(ctx, :caps, [])

    if Ezagent.Identity.AdminAuthority.admin?(caller, caps),
      do: :ok,
      else: {:error, :public_socialware_requires_admin}
  end

  defp authorized?(ctx, needed) do
    ctx
    |> Map.get(:caps, [])
    |> Enum.any?(&Ezagent.Capability.matches?(&1, needed))
  end

  defp fetch_cr(cr_id) do
    case ConfigChangeStore.fetch(cr_id) do
      {:ok, cr} -> {:ok, cr}
      :none -> {:error, :cr_not_found}
    end
  end

  defp assert_workspace(cr, ctx) do
    if cr.workspace_uri == workspace_uri(ctx) do
      :ok
    else
      {:error,
       {:cross_workspace_socialware_cr_denied,
        %{cr_workspace_uri: cr.workspace_uri, caller_workspace_uri: workspace_uri(ctx)}}}
    end
  end

  defp assert_definition_subject(%Definition{name: name}, name), do: :ok

  defp assert_definition_subject(%Definition{name: got}, want),
    do: {:error, {:socialware_cr_subject_mismatch, %{want: want, got: got}}}

  defp normalize_definition(%Definition{} = definition), do: {:ok, definition}
  defp normalize_definition(attrs) when is_map(attrs), do: Definition.new(attrs)
  defp normalize_definition(other), do: {:error, {:invalid_socialware_definition, other}}

  defp subject(name), do: DefinitionRegistry.definition_subject_uri(:unused, name)

  defp subject_name("socialware:" <> name) when name != "", do: {:ok, name}
  defp subject_name(other), do: {:error, {:invalid_socialware_subject, other}}

  defp workspace_uri(ctx), do: Map.fetch!(ctx, :workspace_uri) |> uri_string()

  defp workspace_uri_struct(%URI{} = uri), do: uri
  defp workspace_uri_struct(uri) when is_binary(uri), do: Ezagent.URI.new!(uri)

  defp uri_string(%URI{} = uri), do: URI.to_string(uri)
  defp uri_string(uri) when is_binary(uri), do: uri
end
