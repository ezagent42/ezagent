defmodule Ezagent.Behavior.Session.Legends do
  @moduledoc false
  #
  # Session-scoped legend-registry machinery extracted VERBATIM from
  # `Ezagent.Behavior.Session` (PR-3R helper extraction). The authorization
  # predicates run in the same Session Kind process as the
  # `handle_set_legends/2` / `handle_set_prompt_templates/2` callbacks (the
  # legend write-gate is shared by both); the legend readers are pure
  # delegations to `Ezagent.Behavior.Session.Members`; `system_set_legends/2`
  # is an `Ezagent.Router.dispatch` round-trip identical to running in
  # `Behavior.Session`.

  alias Ezagent.Cmd
  alias Ezagent.Behavior.Session.{ConfigActions, Members}
  alias Ezagent.Routing.Legend

  # The trusted-principal allowlist for `set_legends` — installing a legend is
  # orchestrator/system config (a legend fronts a team + rule-set). Mirrors the
  # provenance-setting trusted-principal pattern. `set_working_copy` STILL uses
  # the older `system_internal`-flag gate (`working_copy_write_authorized?/1`) —
  # codex flagged it shares the same flaw; tracked separately (see report), this
  # PR fixes `set_legends` properly.
  # `orchestrator-tools` removed 2026-06-19 (#154 — principal eliminated): no
  # production path ever dispatched `set_legends` under it (the system path uses
  # `session-internal`; the orchestrator installs legends via its
  # `{:within_session, self}` delegated cap, NOT this allowlist). Only
  # `session-internal` remains a trusted legends principal.
  @legends_trusted_principals ["session-internal"]

  @doc false
  @spec legends_write_authorized?(map()) :: boolean()
  def legends_write_authorized?(ctx) do
    trusted_legends_principal?(ctx) or ConfigActions.orchestrator_cap_present?(ctx)
  end

  # True iff `ctx.caller` is one of the trusted system principals allowed to
  # install legends. The caller is set by the dispatch path, NOT freely by an
  # arbitrary user dispatch (a user dispatch carries the user's own
  # `entity://user/...` caller), so unlike the old `system_internal` boolean
  # this cannot be spoofed by setting a ctx field.
  defp trusted_legends_principal?(ctx) do
    case Map.get(ctx, :caller) do
      %URI{} = caller -> trusted_principal?(caller)
      caller when is_binary(caller) -> caller |> Ezagent.URI.new!() |> trusted_principal?()
      _ -> false
    end
  end

  defp trusted_principal?(%URI{} = caller) do
    caller = caller |> Ezagent.URI.instance() |> URI.to_string()

    Enum.any?(@legends_trusted_principals, fn name ->
      name |> Ezagent.SystemPrincipal.uri() |> URI.to_string() == caller
    end)
  end

  @doc """
  Read the session-scoped legend registry from a `:chat` slice, defaulting to
  `%{}` when the key is absent (a pre-PR-6 Session snapshot — see `create/1`).
  """
  @spec legends_of(map()) :: Legend.registry()
  def legends_of(chat_slice) when is_map(chat_slice) do
    Members.legends_of(chat_slice)
  end

  @doc """
  Resolve a legend NAME against a `:chat` slice's registry to its entry (the
  bound rule-set handle). Delegates to `Ezagent.Routing.Legend.resolve/2`.

  `{:ok, entry}` (carrying `:bound_rule_set` + `:name`) for a registered
  legend, `:error` otherwise. team-routing-unification §3.6 (PR-6, GATE a).
  """
  @spec resolve_legend(map(), String.t()) :: {:ok, Legend.entry()} | :error
  def resolve_legend(chat_slice, name) when is_map(chat_slice) and is_binary(name) do
    Members.resolve_legend(chat_slice, name)
  end

  @doc """
  Member-list rows with folded legends collapsed (team-routing-unification
  §3.6 fold, PR-6, GATE c). Wires this Behavior's `role_name_to_uri/2` into
  `Ezagent.Routing.Legend.fold_members/3` so a legend's `member_set`
  role_names resolve to live member URIs. Pure presentation transform — the
  slice `:members` map is untouched, so every collapsed member stays
  individually `@`-able.

  Returns `[{:legend, name, [URI.t()]} | {:member, URI.t(), meta}]`.
  """
  @spec fold_members(map()) :: [
          {:legend, String.t(), [URI.t()]} | {:member, URI.t(), map()}
        ]
  def fold_members(chat_slice) when is_map(chat_slice) do
    Members.fold_members(chat_slice)
  end

  @doc """
  System-internal path to install the legend registry (team-routing-unification
  §3.6, PR-6). Mirrors `system_set_working_copy/2`: a `chat.set_legends`
  dispatch under the `system://session-internal` principal. Used by tests and
  by the PR-7 template materialization path (which installs a template's
  legends at create_session time, before any orchestrator cap exists).

  Authorization rides the TRUSTED `caller` (`system://session-internal` ∈ the
  `set_legends` allowlist), NOT a ctx flag (codex 2026-06-01 HIGH #2). The old
  `system_internal: true` marker is no longer consulted for legends — it is
  omitted here.
  """
  @spec system_set_legends(URI.t(), Legend.registry()) :: {:ok, map()} | {:error, term()}
  def system_set_legends(%URI{} = session_uri, legends) when is_map(legends) do
    case Ezagent.Router.dispatch(%Cmd{
           target: session_uri,
           action: :set_legends,
           args: %{legends: legends},
           ctx: %{
             caller: Ezagent.SystemPrincipal.uri("session-internal"),
             caps: system_caps("session-internal"),
             reply: {:caller_inbox, self()}
           }
         }) do
      {:ok, %{legends: _} = ok} -> {:ok, ok}
      {:error, _} = err -> err
      other -> {:error, {:unexpected_set_legends_result, other}}
    end
  end

  defp system_caps(name) when is_binary(name) do
    name
    |> Ezagent.SystemPrincipal.uri()
    |> Ezagent.SystemPrincipal.caps()
  end
end
