defmodule Ezagent.Identity.AuthenticatedHolders do
  @moduledoc """
  #189 PR-2 (codex spec-review F4) — the CLOSED declaration of the authenticated
  identity-holder population, by Kind `type_name`.

  An "authenticated holder" is a Kind whose URI can enter the
  `authenticated_principal` slot and must, to self-authorize, present a
  durable, current self-license. This module DECLARES that population; it does
  NOT enforce anything. **No authorization decision consults it in PR-2** — the
  read plane stays legacy-authoritative (the 9 `holder_revoked` reds stay red).
  Enforcement (the principal-gate flip) lands atomically in PR-3.

  Two things depend on this declaration NOW:

    * the **backfill** (`mix ezagent.identity.backfill`) — so it knows which
      Kinds are principals to mirror and which are structurally exempt;
    * the **fleet-completion barrier** — so "fleet complete" has a precise,
      closed meaning and each holder class gets an explicit policy (codex F2).

  ## Classes

    * `:durable_holder` — self-authorizes from a DURABLE self-license that
      survives restart (`:user`, `:agent`, `:session`). Its store row MUST be
      present and parity-correct for the barrier to report complete.
    * `:ephemeral_holder` — an authenticated holder whose persistence is
      `:ephemeral` (`:external_mirror_worker`). It has NO durable legacy
      source in PR-2, so it is DELIBERATELY EXEMPT from the barrier's
      legacy→store parity requirement; its durable identity (mint-on-true-
      creation + generation-gated re-read) is owned by the PR-3 read-cutover.
      Declared here so the exemption is explicit rather than an accidental
      gap (the exact hole codex F2 flags: an ephemeral principal absent from
      both `users` and `kind_snapshots` must not let the barrier claim 100%).
    * `:non_holder` — never occupies `authenticated_principal` as a
      self-licensing subject (`:agent_template`, `:session_template`,
      `:workspace`, `:system`, `:git_task_access`). Structural / bootstrap /
      recipe / policy Kinds; the
      canonical admin's fresh-boot empty-`caps_json` contract lives under the
      `:system`/`:user` structural exception, handled by the barrier.

  The classification is CLOSED: `Ezagent.Identity.AuthenticatedHoldersTest`
  ratchets it against every production Kind `type_name`, so adding a new Kind
  forces an explicit holder/non-holder decision here.
  """

  @classification %{
    user: :durable_holder,
    agent: :durable_holder,
    session: :durable_holder,
    external_mirror_worker: :ephemeral_holder,
    agent_template: :non_holder,
    session_template: :non_holder,
    workspace: :non_holder,
    system: :non_holder,
    # An ephemeral, exact-operation Git-access POLICY entity — never occupies
    # `authenticated_principal` as a self-licensing subject (codex impl-review
    # finding 3: the ratchet now catches its macro `use Ezagent.Kind,
    # type_name: :git_task_access` declaration, so it must be classified).
    git_task_access: :non_holder
  }

  @holder_classes [:durable_holder, :ephemeral_holder]

  @type class :: :durable_holder | :ephemeral_holder | :non_holder

  @doc "The closed `type_name => class` classification map."
  @spec classification() :: %{atom() => class()}
  def classification, do: @classification

  @doc "The class for a Kind `type_name`, or `:unknown` if unclassified."
  @spec classify(atom()) :: class() | :unknown
  def classify(type_name) when is_atom(type_name),
    do: Map.get(@classification, type_name, :unknown)

  @doc "Whether `type_name` is an authenticated holder (durable OR ephemeral)."
  @spec authenticated_holder?(atom()) :: boolean()
  def authenticated_holder?(type_name) when is_atom(type_name),
    do: classify(type_name) in @holder_classes

  @doc "Whether `type_name` is a DURABLE holder (store row required by the barrier)."
  @spec durable_holder?(atom()) :: boolean()
  def durable_holder?(type_name) when is_atom(type_name),
    do: classify(type_name) == :durable_holder

  @doc "Whether `type_name` is an EPHEMERAL holder (barrier-exempt in PR-2)."
  @spec ephemeral_holder?(atom()) :: boolean()
  def ephemeral_holder?(type_name) when is_atom(type_name),
    do: classify(type_name) == :ephemeral_holder

  @doc "The durable-holder `type_name`s (barrier parity population)."
  @spec durable_holder_type_names() :: [atom()]
  def durable_holder_type_names,
    do: for({t, :durable_holder} <- @classification, do: t)

  @doc "The ephemeral-holder `type_name`s (barrier-exempt in PR-2)."
  @spec ephemeral_holder_type_names() :: [atom()]
  def ephemeral_holder_type_names,
    do: for({t, :ephemeral_holder} <- @classification, do: t)
end
