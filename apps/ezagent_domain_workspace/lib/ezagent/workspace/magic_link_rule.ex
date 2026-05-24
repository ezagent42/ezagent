defmodule Ezagent.Workspace.MagicLinkRule do
  @moduledoc """
  SPEC 2026-05-24 v2 PR-A (Allen) — workspace-scoped magic-link rules.

  Replaces the standalone `registration_domains` AppSetting (a flat
  global allow-list) with **per-workspace rules**. A workspace may
  have many rules (OR-combined): e.g. "h2oslabs" accepts both
  `@h2oslabs.com` AND `@h2oslabs.io`.

  ## Rule types

  | `rule_type` | `rule_value` | "Accepts email E" means |
  |---|---|---|
  | `"domain"` | bare domain (`"h2oslabs.com"`) | `E`'s domain (case-insensitive) equals `rule_value` |
  | `"user_list"` | the literal email (`"alice@example.com"`) | `E` (case-insensitive) equals `rule_value` |
  | `"invite_only"` | the recipient email (`"bob@x.com"`) | `E` equals `rule_value` AND a separate invite-token flow has been satisfied (PR-D wires the admin invite UI; PR-A only stores the row) |

  ## OR-combined

  An email matches a workspace iff ANY rule on that workspace matches.

  ## Bidirectional indexing

  - `[:workspace_uri]` index → "does workspace W accept email E?"
    Used by the send-side AND click-side gates (OQ-V2-3: both).
  - `[:rule_type, :rule_value]` index → "which workspaces accept
    emails from domain D?" — used by the registration onboarding
    flow (PR-B) to suggest matching workspaces.
  """

  use Ecto.Schema
  import Ecto.Query
  alias EzagentCore.Repo

  @rule_types ~w(domain user_list invite_only)

  schema "workspace_magic_link_rules" do
    field :workspace_uri, :string
    field :rule_type, :string
    field :rule_value, :string
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
  @type rule_type :: String.t()
  @type decoded :: %{
          id: integer(),
          workspace_uri: String.t(),
          rule_type: rule_type(),
          rule_value: String.t()
        }

  @doc "List of valid `rule_type` values."
  def rule_types, do: @rule_types

  # --- write paths ----------------------------------------------------

  @doc """
  Add a rule to a workspace. Returns `{:ok, decoded}` or `{:error, _}`.

  `rule_type` must be one of `rule_types/0`. `rule_value` is lower-
  cased for case-insensitive matching at read time.
  """
  @spec add(URI.t() | String.t(), rule_type(), String.t()) ::
          {:ok, decoded()} | {:error, term()}
  def add(workspace_uri, rule_type, rule_value)
      when rule_type in @rule_types and is_binary(rule_value) and rule_value != "" do
    ws_str = uri_to_string(workspace_uri)
    normalized_value = normalize_value(rule_type, rule_value)

    changeset =
      %__MODULE__{}
      |> Ecto.Changeset.change(%{
        workspace_uri: ws_str,
        rule_type: rule_type,
        rule_value: normalized_value
      })

    case Repo.insert(changeset) do
      {:ok, row} -> {:ok, decode(row)}
      err -> err
    end
  end

  def add(_, rule_type, _) when rule_type not in @rule_types,
    do: {:error, {:invalid_rule_type, rule_type}}

  def add(_, _, _), do: {:error, :invalid_args}

  @doc "Delete a single rule by ID. Idempotent (no-op for missing)."
  @spec delete(integer()) :: :ok
  def delete(id) when is_integer(id) do
    case Repo.get(__MODULE__, id) do
      nil -> :ok
      row -> Repo.delete!(row) |> case do %{} -> :ok end
    end
  end

  @doc """
  Delete all rules for a workspace. Called during workspace deletion
  to avoid orphaned rule rows.
  """
  @spec delete_all_for(URI.t() | String.t()) :: :ok
  def delete_all_for(workspace_uri) do
    ws_str = uri_to_string(workspace_uri)
    Repo.delete_all(from r in __MODULE__, where: r.workspace_uri == ^ws_str)
    :ok
  end

  # --- read paths ----------------------------------------------------

  @doc "All rules for a workspace, ordered by id."
  @spec list_for(URI.t() | String.t()) :: [decoded()]
  def list_for(workspace_uri) do
    ws_str = uri_to_string(workspace_uri)

    Repo.all(
      from r in __MODULE__,
        where: r.workspace_uri == ^ws_str,
        order_by: r.id
    )
    |> Enum.map(&decode/1)
  end

  @doc """
  Does workspace `workspace_uri` accept `email`? OR-combines all
  rules. Case-insensitive on both sides.

  Used by the send-side gate (`Workspace.accepts_email?/2`) and the
  click-side gate (PR-B `MagicLinkController.consume/2` after token
  verify, per OQ-V2-3 "both send + click").

  **Codex PR-A round-1 HIGH-2 (Allen 2026-05-24):** `invite_only`
  rows DO NOT grant access until PR-D wires the invite-token check.
  Pre-fix, `accepts_email?` treated `invite_only` like `user_list`
  → a stored `invite_only` row was a silent allowlist bypass.
  Post-fix, only `domain` + `user_list` rules grant access; the
  `invite_only` API surface is reserved (the rule can be stored
  for future use, but access requires PR-D's token gate).

  **Codex PR-A round-1 MEDIUM-1:** the matching is pushed down to
  SQL via an `exists` query. The old in-memory scan was an
  auth-path DoS surface (loaded ALL rules for a workspace on every
  check); the new query returns at the first match using the
  `[:workspace_uri]` index + value comparison.
  """
  @spec accepts_email?(URI.t() | String.t(), String.t()) :: boolean()
  def accepts_email?(workspace_uri, email) when is_binary(email) do
    ws_str = uri_to_string(workspace_uri)
    email_lower = email |> String.trim() |> String.downcase()
    domain = extract_domain(email_lower)

    query =
      from r in __MODULE__,
        where:
          r.workspace_uri == ^ws_str and
            ((r.rule_type == "domain" and r.rule_value == ^domain) or
               (r.rule_type == "user_list" and r.rule_value == ^email_lower)),
        select: 1,
        limit: 1

    Repo.exists?(query)
  end

  def accepts_email?(_, _), do: false

  @doc """
  Reverse lookup — which workspaces' rules accept `email`?

  Used by the onboarding LV (PR-B) to suggest workspaces the user
  can join. Returns workspace URIs as strings.

  **Codex PR-A round-1 HIGH-2:** `invite_only` rules are EXCLUDED
  from this lookup (they require PR-D's token gate to grant access;
  they should not appear as a "you can join these" suggestion).
  """
  @spec workspaces_accepting(String.t()) :: [String.t()]
  def workspaces_accepting(email) when is_binary(email) do
    email_lower = email |> String.trim() |> String.downcase()
    domain = extract_domain(email_lower)

    Repo.all(
      from r in __MODULE__,
        where:
          (r.rule_type == "domain" and r.rule_value == ^domain) or
            (r.rule_type == "user_list" and r.rule_value == ^email_lower),
        select: r.workspace_uri,
        distinct: true
    )
  end

  # --- helpers --------------------------------------------------------

  defp decode(%__MODULE__{} = row) do
    %{
      id: row.id,
      workspace_uri: row.workspace_uri,
      rule_type: row.rule_type,
      rule_value: row.rule_value
    }
  end

  defp uri_to_string(%URI{} = uri), do: URI.to_string(uri)
  defp uri_to_string(s) when is_binary(s), do: s

  # `domain` rule values stored bare (no @); `user_list` / `invite_only`
  # stored as the full lowercased email.
  defp normalize_value("domain", v), do: v |> String.trim() |> String.downcase()
  defp normalize_value(_other, v), do: v |> String.trim() |> String.downcase()

  defp extract_domain(email) do
    case String.split(email, "@", parts: 2) do
      [_, domain] -> domain
      _ -> ""
    end
  end
end
