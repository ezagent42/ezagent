defmodule Ezagent.World.CallerDisplay do
  @moduledoc false

  # Human label for an entity URI, used by the World nav account menu and the
  # workspace-switcher chrome. Resolution order: `entity_profiles.display_name`
  # → profile `email` → the URI's HANDLE (its last path segment, e.g.
  # `lin_yilun`). The final tier is the handle — NEVER the raw `entity://…`
  # URI: a missing/unresolvable profile must still render a short human label
  # (matching what the official site shows), not a truncated opaque URI in the
  # top-right menu.

  def name(nil), do: nil

  def name(%URI{} = uri) do
    if Code.ensure_loaded?(Ezagent.Entity.Profile) do
      case apply(Ezagent.Entity.Profile, :get, [uri]) do
        %{display_name: dn} when is_binary(dn) and dn != "" -> dn
        %{email: e} when is_binary(e) and e != "" -> e
        _ -> handle(uri)
      end
    else
      handle(uri)
    end
  end

  def name(_), do: nil

  # The URI's identity handle (last path segment). Falls back to the raw URI
  # string only for URIs with no name segment (structurally shouldn't happen
  # for entity principals, but keeps this total rather than raising).
  defp handle(%URI{} = uri) do
    case Ezagent.URI.name(uri) do
      {:ok, name} -> name
      :error -> URI.to_string(uri)
    end
  end
end
