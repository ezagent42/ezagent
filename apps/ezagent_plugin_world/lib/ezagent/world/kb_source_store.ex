defmodule Ezagent.World.KbSourceStore do
  @moduledoc """
  Validates and persists user-authored KB source documents.

  Every destination is a workspace-scoped `resource://<ws>/kb-source/<name>`
  resolved through `Ezagent.Resource.FsResolver`. Client filenames never become
  paths directly, and exclusive creation prevents an import from replacing an
  existing source.
  """

  alias Ezagent.Resource.FsResolver
  alias Ezagent.URI, as: EzURI

  @max_content_bytes 256_000
  @max_title_length 120
  @allowed_extensions [".md", ".txt"]

  @type stored_source :: %{
          title: String.t(),
          source_uri: String.t(),
          path: String.t()
        }

  @doc "Validate and store one pasted-text or uploaded-file document."
  @spec store(URI.t(), map()) :: {:ok, stored_source()} | {:error, atom() | term()}
  def store(%URI{} = workspace_uri, document) when is_map(document) do
    with {:ok, workspace} <- EzURI.workspace_name(workspace_uri),
         {:ok, title} <- validate_title(Map.get(document, "title")),
         {:ok, content} <- validate_content(Map.get(document, "content")),
         {:ok, extension} <- validate_extension(Map.get(document, "filename")),
         stored_name <- stored_name(title, extension),
         source_uri <- EzURI.resource(workspace, "kb-source", stored_name),
         {:ok, path} <- resolve(source_uri, workspace),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, source_body(title, content, extension), [:binary, :exclusive]) do
      {:ok,
       %{
         title: title,
         source_uri: URI.to_string(source_uri),
         path: path
       }}
    else
      {:error, :eexist} -> {:error, :source_name_collision}
      {:error, reason} -> {:error, reason}
      :none -> {:error, :kb_source_type_unavailable}
    end
  end

  def store(_workspace_uri, _document), do: {:error, :invalid_document}

  @doc "Remove a source created for an import that did not reach the KB index."
  @spec cleanup(stored_source()) :: :ok
  def cleanup(%{path: path}) when is_binary(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} -> :ok
    end
  end

  def cleanup(_source), do: :ok

  @doc false
  def max_content_bytes, do: @max_content_bytes

  defp validate_title(title) when is_binary(title) do
    title = String.trim(title)

    cond do
      title == "" -> {:error, :title_required}
      String.length(title) > @max_title_length -> {:error, :title_too_long}
      true -> {:ok, title}
    end
  end

  defp validate_title(_title), do: {:error, :title_required}

  defp validate_content(content) when is_binary(content) do
    cond do
      not String.valid?(content) -> {:error, :content_not_utf8}
      String.trim(content) == "" -> {:error, :content_required}
      byte_size(content) > @max_content_bytes -> {:error, :content_too_large}
      true -> {:ok, content}
    end
  end

  defp validate_content(_content), do: {:error, :content_required}

  defp validate_extension(nil), do: {:ok, ".md"}
  defp validate_extension(""), do: {:ok, ".md"}

  defp validate_extension(filename) when is_binary(filename) do
    extension = filename |> Path.extname() |> String.downcase()

    if extension in @allowed_extensions,
      do: {:ok, extension},
      else: {:error, :unsupported_file_type}
  end

  defp validate_extension(_filename), do: {:error, :unsupported_file_type}

  defp stored_name(title, extension) do
    slug =
      title
      |> String.downcase()
      |> String.replace(~r/[^\p{L}\p{N}.-]+/u, "-")
      |> String.trim("-")
      |> String.slice(0, 60)
      |> case do
        "" -> "document"
        value -> value
      end

    random = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    "#{random}-#{slug}#{extension}"
  end

  defp source_body(title, content, ".md"), do: "# #{title}\n\n#{content}"
  defp source_body(title, content, ".txt"), do: "#{title}\n\n#{content}"

  defp resolve(source_uri, workspace) do
    case FsResolver.resolve(source_uri, %{workspace: workspace}) do
      {:ok, path} -> {:ok, path}
      :none -> :none
      {:error, reason} -> {:error, reason}
    end
  end
end
