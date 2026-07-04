defmodule Ezagent.Invariants.CapsDataOwnerTest do
  @moduledoc """
  PR-OWN-FINAL invariant (caps-data-ownership SPEC #306 §7 closeout):
  every Behavior that declares non-empty `cap_subjects/0` MUST also
  declare `data_owner/1`.

  Locks the architectural goal of caps-data-ownership-v2: every cap
  has a documented grant authority via the data_owner formalism.
  Without this gate a new Behavior could land with cap_subjects but
  no data_owner — the §5.2 enforcement would silently fall through
  to the legacy admin-cap dispatch check for that Behavior, leaving
  it outside the framework.

  Implementation mirrors `mix ezagent.caps.audit --strict`:
  enumerate loaded `*.Behavior.*` modules; for each that exports
  `cap_subjects/0` returning non-empty list, assert
  `function_exported?(module, :data_owner, 1)`.
  """
  use ExUnit.Case, async: true

  test "every Behavior with cap_subjects/0 declares data_owner/1" do
    # Codex PR-OWN-4 round-1 MED fix: enumerate from compiled BEAM
    # under umbrella apps' build dirs — NOT `:code.all_loaded()`
    # (load order is incidental and a Behavior could evade if no
    # earlier test happened to load it). Walking the build dirs +
    # `Code.ensure_loaded?/1` is deterministic.
    rows =
      umbrella_apps_behavior_modules()
      |> Enum.map(&audit_row/1)
      |> Enum.filter(& &1.cap_subjects?)

    missing =
      rows
      |> Enum.reject(& &1.data_owner?)
      |> Enum.map(& &1.module)
      |> Enum.sort()

    assert missing == [],
           """
           These Behavior modules declare cap_subjects/0 but lack data_owner/1:

             #{missing |> Enum.map_join("\n  ", &inspect/1)}

           caps-data-ownership-v2 SPEC #306 §7 PR-OWN-FINAL requires every
           Behavior with caps to formalize its grant authority via data_owner/1.

           Add `def data_owner(...)` to each missing module. Common shapes:
             - per-entity owner: `def data_owner(%URI{} = uri), do: Ezagent.URI.instance(uri); def data_owner(_), do: :no_owner`
             - workspace-scoped: `def data_owner(_), do: :any`
             - admin-only:       `def data_owner(_), do: :no_owner`
           See SPEC §3 for the full callback contract.
           """
  end

  defp behavior_module?(module) when is_atom(module) do
    s = Atom.to_string(module)

    String.starts_with?(s, "Elixir.Ezagent.ActionSet.") or
      String.contains?(s, ".Behavior.")
  end

  defp behavior_module?(_), do: false

  # Deterministic enumeration of all `*.Behavior.*` modules
  # compiled under the umbrella apps' build dirs. Force-loads each
  # via `Code.ensure_loaded?/1` so `function_exported?/3` works.
  defp umbrella_apps_behavior_modules do
    # All loaded apps that match ezagent_* — these are the umbrella
    # member apps. Mix.Project gives the build dir per app.
    for {app, _, _} <- Application.loaded_applications(),
        Atom.to_string(app) |> String.starts_with?("ezagent"),
        module <- Application.spec(app, :modules) || [],
        behavior_module?(module),
        Code.ensure_loaded?(module),
        uniq: true do
      module
    end
  end

  defp audit_row(module) do
    %{
      module: module,
      cap_subjects?: cap_subjects?(module),
      data_owner?: function_exported?(module, :data_owner, 1)
    }
  end

  defp cap_subjects?(module) do
    if function_exported?(module, :cap_subjects, 0) do
      try do
        case module.cap_subjects() do
          [] -> false
          [_ | _] -> true
          _ -> false
        end
      rescue
        _ -> false
      end
    else
      false
    end
  end
end
