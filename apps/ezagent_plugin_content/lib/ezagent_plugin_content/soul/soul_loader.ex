defmodule EzagentPluginContent.Soul.SoulLoader do
  @moduledoc """
  4-layer soul loading. Load order: framework(L0) → platform(L1) → industry(L2) → template(L3) → tenant override.
  Later layers override earlier ones by section.
  """

  @doc "Load and merge soul templates for a tenant+role. Returns list of binaries (layers)."
  @spec load(binary(), String.t(), String.t()) :: [binary()]
  def load(priv_dir, tid, role) do
    layers = [
      # L0
      read_if_exists(priv_dir, "platform/framework/#{role}/soul.md"),
      # L1
      read_if_exists(priv_dir, "platform/platform/#{role}.md"),
      # L2
      read_if_exists(priv_dir, "platform/industry/cloud-comms/#{role}/soul.md"),
      # L3
      read_if_exists(priv_dir, "platform/templates/#{role}/soul.md"),
      # Tenant override
      read_if_exists(Path.join([priv_dir, "..", "tenants", tid, "sandbox"]), "souls/#{role}_soul.md")
    ]

    Enum.filter(layers, &(&1 != nil))
  end

  defp read_if_exists(dir, path) do
    full = Path.join(dir, path)
    if File.exists?(full), do: File.read!(full), else: nil
  end
end
