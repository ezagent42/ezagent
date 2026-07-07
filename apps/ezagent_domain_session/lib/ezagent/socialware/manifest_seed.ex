defmodule Ezagent.Socialware.ManifestSeed do
  @moduledoc """
  Boot-time local `priv/socialware/*/manifest.yaml` scanner.

  This is the local deploy-seed lane only. Remote config-repo ingestion belongs
  to the registry follow-up.
  """

  alias Ezagent.Socialware.ManifestYaml

  @doc "Return true when boot manifest scanning is enabled for this runtime."
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:ezagent_domain_session, :socialware_manifest_boot_scan, default_enabled?())
  end

  @doc "Scan the OTP app priv/socialware directory if enabled."
  @spec scan_boot_manifests!() :: :ok
  def scan_boot_manifests! do
    if enabled?() do
      :ezagent_domain_session
      |> :code.priv_dir()
      |> Path.join("socialware")
      |> scan_priv_manifests()
      |> case do
        {:ok, _results} ->
          :ok

        {:error, reason} ->
          raise "socialware manifest boot scan failed: #{inspect(reason)}"
      end
    else
      :ok
    end
  end

  @doc "Scan a local directory whose children may contain `manifest.yaml`."
  @spec scan_priv_manifests(Path.t()) :: {:ok, [map()]} | {:error, term()}
  def scan_priv_manifests(root) when is_binary(root) do
    root
    |> manifest_paths()
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
      case import_manifest_path(path) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        {:error, reason} -> {:halt, {:error, {:manifest_seed_failed, path, reason}}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, _} = error -> error
    end
  end

  defp import_manifest_path(path) do
    with {:ok, yaml} <- File.read(path),
         {:ok, attrs} <- ManifestYaml.parse(yaml),
         name when is_binary(name) and name != "" <- Map.get(attrs, "name"),
         ctx <- ManifestYaml.operator_admin_ctx(name, Ezagent.URI.workspace(:system)),
         {:ok, result} <- ManifestYaml.import(yaml, ctx) do
      {:ok, %{path: path, name: name, result: result}}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_manifest_seed, other}}
    end
  end

  defp manifest_paths(root) do
    root
    |> Path.join("*/manifest.yaml")
    |> Path.wildcard()
    |> Enum.sort()
  end

  defp default_enabled?, do: Application.get_env(:ezagent_core, :env) in [:dev, :prod]
end
