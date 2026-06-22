defmodule Ezagent.World.CallerDisplay do
  @moduledoc false

  def name(nil), do: nil

  def name(%URI{} = uri) do
    if Code.ensure_loaded?(Ezagent.Entity.Profile) do
      case apply(Ezagent.Entity.Profile, :get, [uri]) do
        %{display_name: dn} when is_binary(dn) and dn != "" -> dn
        %{email: e} when is_binary(e) and e != "" -> e
        _ -> URI.to_string(uri)
      end
    else
      URI.to_string(uri)
    end
  end

  def name(_), do: nil
end
