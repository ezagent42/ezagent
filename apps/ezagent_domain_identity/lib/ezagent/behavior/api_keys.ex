defmodule Ezagent.ActionSet.ApiKeys do
  @moduledoc """
  ApiKeys Behavior — per-Agent secret storage for outbound API
  credentials (DeepSeek, OpenAI, Anthropic, etc.).

  Slice shape:

      %{
        keys: %{provider :: String.t() => key :: String.t()},
        creator_uri: %URI{} | nil
      }

  ## Why on Agent Kind (Allen 2026-05-26)

  Previously per-User. Allen flipped this — **agents hold their own
  keys**. Reasoning: the credential funds the *agent's* outbound
  request, not the *user's*. A workspace can host multiple agents
  that talk to different providers under different keys; binding
  those keys to a single user (or worse, defaulting to
  `entity://user/system/admin`) flattens the model. Per-agent keys
  also make agent cloning / templating sane (clone receives an
  empty key slot rather than leaking the creator's secret).

  ## Permission model

  - The **agent's creator** can view / rotate / delete keys (recorded
    in slice as `:creator_uri` at instantiate time; durable in
    `:api_keys` slice — does NOT depend on the ephemeral
    `Ezagent.AgentLineage` ETS).
  - Workspace admin holds wildcard caps and can edit any agent's keys.
  - The agent ITSELF holds the read cap (`get_api_key`) for its own URI
    via `default_grants_from_data_owner/2` (self-grant — agent reads
    its own key to make outbound requests).

  Cap enforcement happens at dispatch step 5.5 like every other
  Behavior — this module trusts the dispatch-level check and just
  mutates / reads the slice.

  ## Secret handling

  - `:list_api_keys` returns **masked** values (`sk-abcd...wxyz`) for
    UI display. Never returns the plaintext.
  - `:get_api_key` returns the **plaintext** (callers need it to make
    the actual HTTP request). Cap-gated; never logged.
  - Invariant test: API key plaintext must never appear in Audit
    invocation rows. Enforced by per-action `result` redaction in
    audit writer.

  ## P2-b migration (2026-05-28)

  Migrated to the new `use Ezagent.ActionSet` action/handler contract
  per SPEC #445 §4 + §6.2. Legacy `invoke/4` replaced by
  `handle_<action>/2`. All actions are pure slice mutations / reads —
  no DB / PubSub side effects — so effects are limited to `:set`
  (put/delete a key) and `:emit` (audit event). The `:list_api_keys`
  and `:get_api_key` reads use `ctx[:read]` to access the slice
  instead of receiving it as an arg.

  ## Phase B migration (2026-05-29) — `use Ezagent.Lifecycle`

  Converted to the Lifecycle developer API per SPEC
  `docs/superpowers/specs/2026-05-29-lifecycle-hooks-design.md` §5.
  STATE-ONLY: `keys` + `creator_uri` are both PERSISTENT, no
  PID/ref/ETS/port/subprocess transients exist, so `init_slice/1` →
  `create/1` and `activate/2` is the macro-injected no-op rebuild
  (omitted). The auto-derived `state_slice` (`:api_keys`) matches the
  old explicit one — no override marker needed. Handler bodies are
  byte-identical (`ctx[:read]` works unchanged through the two-container
  ctx). `required_caps/0` + `data_owner/1` pass through verbatim.
  """

  use Ezagent.Lifecycle

  action(:list_api_keys,
    args: %{},
    returns: %{api_keys: {:list, :map}},
    caps: [{:list_api_keys, kind: :any}],
    description: "List the agent's stored API keys with masked values",
    modes: [:call]
  )

  action(:put_api_key,
    args: %{provider: :string, key: :string},
    returns: %{ok: :boolean, provider: :string},
    caps: [{:put_api_key, kind: :any}],
    description: "Store or replace the agent's API key for a provider",
    modes: [:call]
  )

  action(:delete_api_key,
    args: %{provider: :string},
    returns: %{ok: :boolean, provider: :string},
    caps: [{:delete_api_key, kind: :any}],
    description: "Delete the agent's API key for a provider",
    modes: [:call]
  )

  action(:get_api_key,
    args: %{provider: :string},
    returns: %{key: :string, provider: :string},
    caps: [{:get_api_key, kind: :any}],
    description: "Fetch the agent's plaintext API key for a provider",
    modes: [:call]
  )

  # =================================================================
  # Explicit `required_caps/0` — preserved as `kind: :any` (ApiKeys
  # is attached to multiple agent-flavor Kinds; see moduledoc).
  # The auto-derived macro version would also produce `:any` so this
  # override is technically a no-op, but kept explicit for parity
  # with the pre-migration shape + future-proofing against macro
  # default changes.
  # =================================================================
  def required_caps do
    %{
      list_api_keys: Ezagent.Capability.cap(:any, __MODULE__, :list_api_keys),
      put_api_key: Ezagent.Capability.cap(:any, __MODULE__, :put_api_key),
      delete_api_key: Ezagent.Capability.cap(:any, __MODULE__, :delete_api_key),
      get_api_key: Ezagent.Capability.cap(:any, __MODULE__, :get_api_key)
    }
  end

  # =================================================================
  # Lifecycle state — `create/1` builds the PERSISTENT state once
  # (Phase B; was `init_slice/1`). No transients → `activate/2` is the
  # macro-injected no-op. `state_slice` is auto-derived to `:api_keys`.
  # =================================================================

  @impl Ezagent.Lifecycle
  def create(args) do
    {:ok,
     %{
       keys: %{},
       creator_uri: Map.get(args, :creator_uri)
     }}
  end

  # =================================================================
  # New-contract action handlers (§6.2 — replace invoke/4)
  # =================================================================

  def handle_list_api_keys(_args, ctx) do
    keys = ctx[:read].(:keys, %{})

    listing =
      keys
      |> Enum.map(fn {provider, key} -> %{provider: provider, masked: mask(key)} end)
      |> Enum.sort_by(& &1.provider)

    # Read-only — no slice mutation.
    {:ok, %{api_keys: listing}, []}
  end

  def handle_put_api_key(%{provider: provider, key: key}, ctx)
      when is_binary(provider) and is_binary(key) and provider != "" and key != "" do
    current_keys = ctx[:read].(:keys, %{})
    new_keys = Map.put(current_keys, provider, key)

    {:ok, %{ok: true, provider: provider},
     [
       {:set, :keys, new_keys},
       {:emit, :api_key_put, %{provider: provider, at: DateTime.utc_now()}}
     ]}
  end

  def handle_put_api_key(args, _ctx) do
    {:error, {:bad_args, "put_api_key requires {provider, key} as non-empty strings", args}}
  end

  def handle_delete_api_key(%{provider: provider}, ctx) when is_binary(provider) do
    current_keys = ctx[:read].(:keys, %{})
    new_keys = Map.delete(current_keys, provider)

    {:ok, %{ok: true, provider: provider},
     [
       {:set, :keys, new_keys},
       {:emit, :api_key_deleted, %{provider: provider, at: DateTime.utc_now()}}
     ]}
  end

  def handle_delete_api_key(args, _ctx) do
    {:error, {:bad_args, "delete_api_key requires {provider: String}", args}}
  end

  def handle_get_api_key(%{provider: provider}, ctx) when is_binary(provider) do
    keys = ctx[:read].(:keys, %{})

    case Map.fetch(keys, provider) do
      {:ok, key} -> {:ok, %{key: key, provider: provider}, []}
      :error -> {:error, {:no_api_key, provider}}
    end
  end

  def handle_get_api_key(args, _ctx) do
    {:error, {:bad_args, "get_api_key requires {provider: String}", args}}
  end

  # =================================================================
  # Helpers
  # =================================================================

  @doc """
  Mask an API key for UI display.

      mask("sk-1234567890abcdef") => "sk-1234...cdef"

  Short keys (< 12 chars) collapse to `***`. Non-sk keys keep the
  same shape but with literal first 4 / last 4.
  """
  @spec mask(String.t()) :: String.t()
  def mask(key) when is_binary(key) do
    cond do
      String.length(key) < 12 ->
        "***"

      String.starts_with?(key, "sk-") ->
        rest = String.replace_prefix(key, "sk-", "")
        "sk-" <> String.slice(rest, 0..3) <> "..." <> String.slice(rest, -4..-1)

      true ->
        String.slice(key, 0..3) <> "..." <> String.slice(key, -4..-1)
    end
  end

  # Allen 2026-05-26 — agent-Kind ApiKeys data_owner. Three resolution
  # tiers (in order):
  #
  #  1. `:api_keys` slice's `:creator_uri` — durable via the Agent
  #     Kind's `{:snapshot, :on_change}` persistence.
  #  2. `Ezagent.AgentLineage.lookup/1` fallback (codex HIGH-1 closure).
  #  3. `:no_owner` — neither source has a record.
  def data_owner(%URI{scheme: "entity"} = agent_uri) do
    if Ezagent.URI.type?(agent_uri, :agent) do
      case Ezagent.Kind.read(agent_uri, :api_keys, spawn: :never) do
        {:ok, %{creator_uri: %URI{} = creator}} ->
          creator

        _ ->
          case lineage_lookup(agent_uri) do
            {:ok, %URI{} = creator} -> creator
            _ -> :no_owner
          end
      end
    else
      :no_owner
    end
  end

  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner

  # Wrap `Ezagent.AgentLineage.lookup/1` so a missing/un-booted
  # registry degrades gracefully (no crash, just `:no_owner`).
  defp lineage_lookup(agent_uri) do
    if Code.ensure_loaded?(Ezagent.AgentLineage) and
         function_exported?(Ezagent.AgentLineage, :lookup, 1) do
      Ezagent.AgentLineage.lookup(agent_uri)
    else
      :error
    end
  rescue
    _ -> :error
  end
end
