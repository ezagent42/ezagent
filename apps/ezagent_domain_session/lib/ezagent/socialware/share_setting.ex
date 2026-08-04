defmodule Ezagent.Socialware.ShareSetting do
  @moduledoc """
  The per-target **sharing setting** — URI-share unification (A1).

  Sharing has two decoupled layers (the Feishu model):

    * **Permission = caps.** Who holds a cap toward a target = who has access.
      Direct grants + already-claimed collaborators live here; revoke per-person
      with `Ezagent.Identity.Grant.revoke_cap/3` (see `grantees_of/2` to list
      them). This module does NOT touch that layer.
    * **Sharing setting = this per-target toggle.** Whether a share LINK lets
      people SELF-ACQUIRE a cap (without being individually granted), and at what
      openness — like a document's "link sharing: off / anyone-with-link" switch.

  The **authority to share lives HERE**, not in the link: only the target's
  `data_owner` may `enable/5` it (verified against the CURRENT owner), so turning
  the setting on IS the owner's authorization. A share link is therefore a
  STATELESS pointer to the target (`Ezagent.Cap.ShareToken`); `claim` reads this
  setting and mints only if it is enabled. This subsumes the old
  "issuer-in-token" scheme (codex M1: authority now checked at the resource) AND
  gives revocation for free (codex D3: `disable/2` = one flip kills every
  outstanding link to that target, without touching already-granted caps).

  `visibility` spans the openness spectrum as a superset:

    * `:link_login` — an authenticated clicker who has the link gets a person-cap
      (implemented here);
    * `:link_anon` — the most-open level (anonymous access). A dedicated
      per-resource PUBLIC session is provisioned for the target (one shared thing
      per session, so an anon visitor can never reach anyone else's share), the
      target is bound into it, and it is marked `web_anon_access`
      (`Ezagent.Socialware.PublicView`). That provisioning is ORCHESTRATION and
      lives in `Ezagent.Socialware.AnonShare`; this module only persists the
      result and stays fail-closed on its own — `enable/5` refuses a `link_anon`
      row without an `:anon_session_uri` (`:anon_share_requires_session`), so the
      enum can never record a visibility that promises anonymous access with
      nowhere for a visitor to land. `by_anon_session/1` is the reverse lookup the
      anon read path uses.

  One row per target. Modeled on the per-session `web_anon_access` visibility
  policy, but per-target.
  """
  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query, only: [where: 3]

  alias EzagentCore.Repo

  @primary_key {:target_uri, :string, autogenerate: false}
  schema "socialware_share_settings" do
    field(:enabled, :boolean, default: false)
    field(:visibility, :string, default: "link_login")
    field(:behavior, :string)
    field(:actions_json, :string, default: "[]")
    field(:access, :string)
    field(:granter_uri, :string)
    field(:workspace_uri, :string)
    # A5 (`link_anon`) — the DEDICATED public session provisioned to show this
    # target. NULL for every `link_login` row. Unique when set: one public
    # session shows exactly one target, which is what makes the anon page
    # structurally isolated (a visitor cannot reach anyone else's share).
    field(:anon_session_uri, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @visibilities ~w(link_login link_anon)

  @doc """
  Turn sharing ON for `target`: an owner-authorized toggle declaring that a share
  link grants `behavior`'s `actions` (at `:read` / `:operate` `access`).

  `owner` MUST be the target's CURRENT `data_owner` (verified) — this IS the
  authorization for every subsequent claim. Idempotent upsert (one row per
  target). Returns `{:ok, setting}` or a fail-closed error.
  """
  @spec enable(URI.t(), URI.t(), module(), [atom()], keyword()) :: {:ok, t()} | {:error, term()}
  def enable(%URI{} = target, %URI{} = owner, behavior, actions, opts \\ [])
      when is_atom(behavior) and is_list(actions) and actions != [] do
    access = Keyword.get(opts, :access, :read)
    visibility = opts |> Keyword.get(:visibility, :link_login) |> to_string()

    cond do
      visibility not in @visibilities ->
        {:error, :invalid_share_visibility}

      # `link_anon` is the superset's most-open level. Its wiring — provision a
      # DEDICATED per-resource public session (one shared thing per session, so an
      # anon visitor can never reach anyone else's share), bind the target into it
      # and mark it `web_anon_access` — is ORCHESTRATION, not persistence, so it
      # lives in `Ezagent.Socialware.AnonShare`. This module stays fail-closed on
      # its own: a `link_anon` row is only writable once that session exists, so
      # the enum value can never be persisted in a half-working state (a row whose
      # visibility promises anonymous access with nowhere for a visitor to land).
      visibility == "link_anon" and is_nil(Keyword.get(opts, :anon_session_uri)) ->
        {:error, :anon_share_requires_session}

      # …and it must be the session DERIVED FROM THIS TARGET. Without this, a row
      # could point a share at any other public session — say the marketing site —
      # which would render this target's data on that page AND mint its read key
      # to every visitor admitted there. The unique partial index only stops two
      # rows sharing one session; this stops one row borrowing someone else's.
      visibility == "link_anon" and
          not derived_anon_session?(target, Keyword.get(opts, :anon_session_uri)) ->
        {:error, :anon_share_session_not_derived}

      true ->
        with :ok <- assert_current_owner(target, behavior, owner) do
          upsert(%{
            target_uri: uri_string(target),
            enabled: true,
            visibility: visibility,
            behavior: behavior_string(behavior),
            actions_json: encode_actions(actions),
            access: to_string(access),
            granter_uri: uri_string(owner),
            workspace_uri: uri_string(Ezagent.Capability.workspace_of(target)),
            anon_session_uri: opts |> Keyword.get(:anon_session_uri) |> maybe_uri_string()
          })
        end
    end
  end

  @doc """
  The ENABLED anon share whose dedicated public session is `session_uri`, or
  `nil` — the REVERSE of `anon_session_uri`.

  This is the anon read path's only question: "this public session is showing
  which target, under what behavior/actions?". Kept as a single indexed lookup
  (unique partial index) rather than a second binding table, so the share row
  stays the one source of truth for an anon share.
  """
  @spec by_anon_session(URI.t()) :: t() | nil
  def by_anon_session(%URI{} = session_uri) do
    key = uri_string(session_uri)

    __MODULE__
    |> where([s], s.anon_session_uri == ^key and s.enabled == true)
    |> Repo.one()
  end

  defp maybe_uri_string(nil), do: nil
  defp maybe_uri_string(%URI{} = uri), do: uri_string(uri)
  defp maybe_uri_string(str) when is_binary(str), do: str

  # The stock template the dedicated public session is created from (see
  # `AnonShare`) — part of the URI derivation, so it is pinned next to it.
  @anon_template_name "default"

  @doc """
  The dedicated public session a `link_anon` row for `target` must point at —
  a pure, no-I/O derivation: a session URI in the target's OWN workspace, on
  the stock template, named `r-<sha256-16hex-of-target>`.

  It lives HERE, with the row whose invariant it is, so persistence can enforce
  "this row points at its OWN session" without reaching up into the provisioning
  layer. `Ezagent.Socialware.AnonShare` provisions against it.
  """
  @spec anon_session_uri_for(URI.t()) :: URI.t()
  def anon_session_uri_for(%URI{} = target) do
    instance = Ezagent.URI.instance(target)

    digest =
      :crypto.hash(:sha256, Ezagent.URI.stable_key(instance))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    workspace_name =
      instance |> Ezagent.Capability.workspace_of() |> Ezagent.URI.workspace_name!()

    Ezagent.URI.session(workspace_name, @anon_template_name, "r-" <> digest)
  end

  defp derived_anon_session?(%URI{} = target, session) do
    case maybe_uri_string(session) do
      nil -> false
      given -> given == uri_string(anon_session_uri_for(target))
    end
  end

  @doc """
  Turn sharing OFF for `target` — the revocation (codex D3). Every outstanding
  link to `target` stops working immediately (claim reads `enabled: false`);
  already-granted caps are UNTOUCHED (revoke those separately per-person). Only
  the target's current `data_owner` may disable. No-op if there is no setting.
  """
  @spec disable(URI.t(), URI.t()) :: {:ok, t() | nil} | {:error, term()}
  def disable(%URI{} = target, %URI{} = owner) do
    case get(target) do
      nil ->
        {:ok, nil}

      %__MODULE__{behavior: b} = setting when is_binary(b) ->
        with :ok <- assert_current_owner(target, Module.concat([b]), owner) do
          setting
          |> change(%{enabled: false})
          |> Repo.update()
        end
    end
  end

  @doc "The raw sharing setting for `target`, or `nil`."
  @spec get(URI.t()) :: t() | nil
  def get(%URI{} = target), do: Repo.get(__MODULE__, uri_string(target))

  @doc """
  The ENABLED sharing setting for `target`, or `nil` if sharing is off / unset.
  The claim edge reads this to decide what (if anything) to mint.
  """
  @spec active(URI.t()) :: t() | nil
  def active(%URI{} = target) do
    case get(target) do
      %__MODULE__{enabled: true} = setting -> setting
      _ -> nil
    end
  end

  @doc "Decode a setting's stored behavior string back to the ActionSet module."
  @spec behavior_module(t()) :: module()
  def behavior_module(%__MODULE__{behavior: b}) when is_binary(b), do: Module.concat([b])

  @doc "Decode a setting's stored actions back to an atom list."
  @spec actions(t()) :: [atom()]
  def actions(%__MODULE__{actions_json: json}) when is_binary(json) do
    json |> Jason.decode!() |> Enum.map(&String.to_existing_atom/1)
  end

  # --- internals ------------------------------------------------------------

  defp assert_current_owner(target, behavior, owner) do
    case Ezagent.CapabilityRegistry.data_owner_of(behavior, Ezagent.URI.instance(target)) do
      %URI{} = current ->
        if same_instance?(owner, current),
          do: :ok,
          else: {:error, {:share_setting_not_target_owner, owner, current}}

      _ ->
        {:error, {:share_setting_target_ownerless, target}}
    end
  end

  defp upsert(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :target_uri,
      :enabled,
      :visibility,
      :behavior,
      :actions_json,
      :access,
      :granter_uri,
      :workspace_uri,
      :anon_session_uri
    ])
    |> validate_required([:target_uri, :enabled, :visibility, :workspace_uri])
    |> Repo.insert(
      on_conflict:
        {:replace,
         [
           :enabled,
           :visibility,
           :behavior,
           :actions_json,
           :access,
           :granter_uri,
           :anon_session_uri,
           :updated_at
         ]},
      conflict_target: :target_uri
    )
  end

  defp same_instance?(a, b) do
    Ezagent.URI.stable_key(Ezagent.URI.instance(a)) ==
      Ezagent.URI.stable_key(Ezagent.URI.instance(b))
  end

  defp behavior_string(behavior) when is_atom(behavior), do: inspect(behavior)
  defp encode_actions(actions), do: Jason.encode!(Enum.map(actions, &Atom.to_string/1))
  defp uri_string(%URI{} = uri), do: uri |> Ezagent.URI.instance() |> URI.to_string()
end
