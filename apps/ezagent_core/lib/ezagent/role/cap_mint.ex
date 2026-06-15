defmodule Ezagent.Role.CapMint do
  @moduledoc """
  Fail-closed cap authorization + minting for role materialization (task #54
  §2.3.1).

  This is the cap half of materialization that `Ezagent.Role.Compose`
  deliberately does NOT do, because it needs the full agent context a
  context-free composer lacks. Given a role's `requested_caps` (the authorized
  REQUEST templates carrying `behavior`/`action`) and the agent's
  materialization context (`kind`, `instance`, `workspace_uri`, `granter`),
  `mint/3`:

  1. builds the concrete needed-cap for each request — injecting `kind` (flavor)
     + `instance`/`workspace_uri` (the materialized agent), and canonicalizing
     the request's `behavior` (string → module) / `action` (string → atom)
     values;
  2. authorizes it **fail-closed** against the injected `policy` predicate
     (`requested ∩ {flavor/tenant permit}`, §2.3.1) — kept ONLY on a strict
     `true`; a non-`true` return OR a raising predicate drops the cap;
  3. mints the canonical `%Ezagent.Capability{}` via
     `Ezagent.Capability.normalize!/2` (the sole grant chokepoint, which
     mandates `workspace_uri` — no silent cross-workspace default), dropping any
     mint failure fail-closed.

  A rejected or un-mintable cap is DROPPED, never copied — `mint/3` returns only
  the caps that survived BOTH the policy and the chokepoint.
  """

  alias Ezagent.Capability

  @type agent_ctx :: %{
          required(:kind) => atom(),
          required(:instance) => URI.t(),
          required(:workspace_uri) => URI.t(),
          required(:granter) => URI.t()
        }

  @doc """
  Mint the authorized, concrete capabilities for `requested_caps` under the
  agent context, fail-closed. See the moduledoc.
  """
  @spec mint([map()], agent_ctx(), (map() -> boolean())) :: [Capability.t()]
  def mint(
        requested_caps,
        %{kind: kind, instance: %URI{} = inst, workspace_uri: %URI{} = ws, granter: granter},
        policy
      )
      when is_list(requested_caps) and is_function(policy, 1) do
    requested_caps
    |> Enum.map(&build_needed(&1, kind, inst, ws))
    |> Enum.filter(&authorized?(policy, &1))
    |> Enum.map(&safe_mint(&1, granter))
    |> Enum.reject(&is_nil/1)
  end

  # Build the concrete needed-cap: inject the materialization axes + canonicalize
  # the request's behavior/action VALUES (atom/string-key tolerant).
  defp build_needed(cap, kind, inst, ws) do
    %{
      kind: kind,
      behavior: canon_module(axis(cap, :behavior)),
      action: canon_atom(axis(cap, :action)),
      instance: inst,
      workspace_uri: ws
    }
  end

  defp axis(cap, key), do: Map.get(cap, key) || Map.get(cap, Atom.to_string(key))

  # string module-name → module atom (existing only — no atom-table growth);
  # unresolved → left as the string so the policy/chokepoint rejects it.
  defp canon_module(s) when is_binary(s) do
    String.to_existing_atom(if String.starts_with?(s, "Elixir."), do: s, else: "Elixir." <> s)
  rescue
    ArgumentError -> s
  end

  defp canon_module(v), do: v

  defp canon_atom(s) when is_binary(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> s
  end

  defp canon_atom(v), do: v

  # Total + fail-closed: keep ONLY on a strict `true`; a non-true return OR a
  # raising/total-violating predicate drops the cap.
  defp authorized?(policy, needed) do
    policy.(needed) == true
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  # Mint via the grant chokepoint; any failure (e.g. an unresolved string
  # behavior the policy let through, a missing axis) drops the cap fail-closed.
  defp safe_mint(needed, granter) do
    Capability.normalize!(needed, granter)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end
end
