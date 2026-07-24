defmodule Ezagent.Entity.Profile do
  @moduledoc """
  Username & Auth M1 — entity-agnostic display profile store.

  One row per Entity URI. Holds the *mutable* attributes (`display_name`,
  `email`) that hang off the *immutable* URI primary key. `email` is
  user-only (NULL for agents) and the resolution key for magic-link
  login (M3).

  Schema + facade in one module, matching the `Ezagent.Users` /
  `Ezagent.Entity.Token` pattern. Display-side reads go through
  `Ezagent.EntityPresenter`; this module owns writes + lookups.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias EzagentCore.Repo

  @max_display_name_length 255

  @primary_key {:entity_uri, :string, autogenerate: false}
  schema "entity_profiles" do
    field(:display_name, :string)
    field(:email, :string)
    # Phase 9 PR-6 (SPEC v3 §7) — per-tenant data isolation. NOT NULL;
    # derived from `entity_uri` at upsert time. Profile rows for
    # `entity://user/team-alpha/alice` are scoped to workspace://team-alpha
    # — homonym entities in other workspaces have independent profiles.
    field(:workspace_uri, :string)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "Insert-or-update a profile keyed by `entity_uri`."
  @spec upsert(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def upsert(attrs) when is_map(attrs) do
    attrs = normalize(attrs)
    existing = Repo.get(__MODULE__, attrs.entity_uri) || %__MODULE__{}

    existing
    |> cast(attrs, [:entity_uri, :display_name, :email, :workspace_uri])
    |> validate_required([:entity_uri, :display_name, :workspace_uri])
    |> validate_length(:display_name, max: @max_display_name_length)
    |> unique_constraint(:email, name: :entity_profiles_email_lower_index)
    |> unique_constraint(:display_name,
      name: :entity_profiles_agent_workspace_display_name_index
    )
    |> Repo.insert_or_update()
  end

  @doc "Ensure an Agent has a workspace-unique display name."
  @spec ensure_agent_display_name(URI.t(), String.t()) ::
          {:ok, t()} | {:error, Ecto.Changeset.t() | :not_agent_uri}
  def ensure_agent_display_name(%URI{} = uri, base_name) when is_binary(base_name) do
    if agent_uri?(uri) do
      case get(uri) do
        %__MODULE__{} = profile ->
          {:ok, profile}

        nil ->
          workspace_uri = Ezagent.Persistence.workspace_uri_for!(uri)
          insert_agent_display_name(uri, workspace_uri, String.trim(base_name), 1)
      end
    else
      {:error, :not_agent_uri}
    end
  end

  @doc "Fetch a profile by entity URI. Returns `nil` if absent."
  @spec get(URI.t() | String.t()) :: t() | nil
  def get(uri), do: Repo.get(__MODULE__, to_str(uri))

  @doc "Resolve an email (case-insensitive) to its profile. `nil` if none."
  @spec by_email(String.t()) :: t() | nil
  def by_email(email) when is_binary(email) do
    down = String.downcase(String.trim(email))
    Repo.one(from(p in __MODULE__, where: fragment("lower(?)", p.email) == ^down))
  end

  def by_email(_), do: nil

  defp insert_agent_display_name(uri, workspace_uri, base_name, suffix) do
    case display_name_candidate(base_name, suffix) do
      {:ok, display_name} ->
        do_insert_agent_display_name(uri, workspace_uri, base_name, display_name, suffix)

      :error ->
        changeset =
          %__MODULE__{}
          |> agent_profile_changeset(%{
            entity_uri: to_str(uri),
            display_name: String.duplicate("x", @max_display_name_length + 1),
            email: nil,
            workspace_uri: workspace_uri
          })
          |> add_error(:display_name, "could not allocate a bounded numeric suffix")

        {:error, changeset}
    end
  end

  defp do_insert_agent_display_name(uri, workspace_uri, base_name, display_name, suffix) do
    %__MODULE__{}
    |> agent_profile_changeset(%{
      entity_uri: to_str(uri),
      display_name: display_name,
      email: nil,
      workspace_uri: workspace_uri
    })
    |> Repo.insert()
    |> case do
      {:ok, profile} ->
        {:ok, profile}

      {:error, changeset} ->
        cond do
          unique_constraint?(changeset, :entity_uri, "entity_profiles_pkey") ->
            case get(uri) do
              %__MODULE__{} = profile -> {:ok, profile}
              nil -> {:error, changeset}
            end

          unique_constraint?(
            changeset,
            :display_name,
            "entity_profiles_agent_workspace_display_name_index"
          ) ->
            insert_agent_display_name(uri, workspace_uri, base_name, suffix + 1)

          true ->
            {:error, changeset}
        end
    end
  end

  defp agent_profile_changeset(profile, attrs) do
    profile
    |> cast(attrs, [:entity_uri, :display_name, :email, :workspace_uri])
    |> validate_required([:entity_uri, :display_name, :workspace_uri])
    |> validate_length(:display_name, max: @max_display_name_length)
    |> unique_constraint(:entity_uri, name: :entity_profiles_pkey)
    |> unique_constraint(:display_name,
      name: :entity_profiles_agent_workspace_display_name_index
    )
  end

  defp unique_constraint?(changeset, field, name) do
    Enum.any?(changeset.errors, fn
      {^field, {_message, details}} ->
        details[:constraint] == :unique and details[:constraint_name] == name

      _ ->
        false
    end)
  end

  defp display_name_candidate(base_name, 1), do: {:ok, base_name}

  defp display_name_candidate(base_name, suffix) when suffix > 1 do
    suffix_text = "-#{suffix}"
    available_base_length = @max_display_name_length - String.length(suffix_text)

    if available_base_length >= 0 do
      candidate =
        base_name
        |> String.slice(0, available_base_length)
        |> Kernel.<>(suffix_text)

      {:ok, candidate}
    else
      :error
    end
  end

  defp agent_uri?(%URI{} = uri),
    do: Ezagent.URI.bare_principal?(uri) and Ezagent.URI.type?(uri, :agent)

  # entity_uri stored as string; email lower-cased + trimmed so the
  # uniqueness invariant means what callers expect.
  defp normalize(attrs) do
    attrs
    |> Map.new(fn {k, v} -> {to_atom(k), v} end)
    |> Map.update(:entity_uri, nil, &to_str/1)
    |> then(fn m ->
      case Map.get(m, :email) do
        e when is_binary(e) and e != "" -> Map.put(m, :email, String.downcase(String.trim(e)))
        _ -> Map.put(m, :email, nil)
      end
    end)
    # Phase 9 PR-6 — derive workspace_uri from entity_uri if not
    # already supplied. Tests / callers may pre-set it; the derivation
    # is the canonical default for entity URIs.
    |> then(fn m ->
      case Map.get(m, :workspace_uri) do
        nil ->
          case Map.get(m, :entity_uri) do
            uri when is_binary(uri) and uri != "" ->
              Map.put(m, :workspace_uri, Ezagent.Persistence.workspace_uri_for!(uri))

            _ ->
              m
          end

        _already_set ->
          m
      end
    end)
  end

  defp to_atom(a) when is_atom(a), do: a
  defp to_atom(s) when is_binary(s), do: String.to_existing_atom(s)
  defp to_str(%URI{} = u), do: URI.to_string(u)
  defp to_str(s) when is_binary(s), do: s
end
