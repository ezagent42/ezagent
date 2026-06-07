defmodule Ezagent.Uploads do
  @moduledoc """
  Upload resource path resolver.

  Chat attachments are addressed as `resource://<workspace>/uploads/<name>`.
  This module owns the filesystem projection for that resource type so callers
  do not reach into `Ezagent.Home` directly.
  """

  @attr :upload_path
  @type_segment "uploads"

  @doc "The `Ezagent.UriQuery` attribute this module owns."
  @spec attr() :: atom()
  def attr, do: @attr

  @doc "The `resource://` type segment for chat uploads."
  @spec type_segment() :: String.t()
  def type_segment, do: @type_segment

  @doc "Register the upload path UriQuery resolver."
  @spec register() :: :ok | {:error, term()}
  def register do
    case Ezagent.UriQuery.register(@attr, &__MODULE__.resolve_path/1) do
      :ok -> :ok
      {:error, {:already_registered, @attr}} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc "Ensure the active profile's uploads directory exists."
  @spec ensure_dir!() :: :ok
  def ensure_dir! do
    File.mkdir_p!(dir!())
  end

  @doc "Return the active profile's uploads directory."
  @spec dir!() :: String.t()
  def dir! do
    Ezagent.Home.path(:uploads)
  end

  @doc "Build a resource URI for a stored upload name."
  @spec resource_uri(String.t(), String.t()) :: URI.t()
  def resource_uri(workspace_name, stored_name)
      when is_binary(workspace_name) and is_binary(stored_name) do
    Ezagent.URI.resource(workspace_name, @type_segment, stored_name)
  end

  @doc "Resolve a stored upload filename or upload resource URI into its filesystem path."
  @spec path!(String.t() | URI.t()) :: String.t()
  def path!(stored_name) when is_binary(stored_name) do
    resolve!(Ezagent.URI.resource("system", @type_segment, Path.basename(stored_name)))
  end

  def path!(%URI{} = resource_uri) do
    resolve!(resource_uri)
  end

  @doc "Copy a LiveView upload temp file into the upload store and return its resource URI."
  @spec store!(String.t(), String.t(), String.t()) :: URI.t()
  def store!(workspace_name, stored_name, tmp_path)
      when is_binary(workspace_name) and is_binary(stored_name) and is_binary(tmp_path) do
    :ok = ensure_dir!()
    resource_uri = resource_uri(workspace_name, stored_name)
    File.cp!(tmp_path, path!(resource_uri))
    resource_uri
  end

  @doc false
  @spec resolve_path(term()) :: Ezagent.UriQuery.result()
  def resolve_path(%URI{scheme: "resource"} = uri) do
    with true <- Ezagent.URI.type?(uri, @type_segment),
         {:ok, name} <- Ezagent.URI.name(uri) do
      {:ok, Path.join(Ezagent.Home.path(:uploads), Path.basename(name))}
    else
      false -> :none
      :error -> :none
    end
  end

  def resolve_path(_), do: :none

  defp resolve!(arg) do
    :ok = register()

    case Ezagent.UriQuery.resolve(@attr, arg) do
      {:ok, path} when is_binary(path) ->
        path

      :none ->
        raise ArgumentError, "not an upload resource: #{inspect(arg)}"

      {:error, reason} ->
        raise ArgumentError, "could not resolve upload path: #{inspect(reason)}"
    end
  end
end
