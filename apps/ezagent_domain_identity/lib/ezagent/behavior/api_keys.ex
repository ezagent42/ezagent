defmodule Ezagent.Behavior.ApiKeys do
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
  """

  @behaviour Ezagent.Behavior

  @impl Ezagent.Behavior
  def actions, do: [:list_api_keys, :put_api_key, :delete_api_key, :get_api_key]

  # Allen 2026-05-26 flip from User Kind. ApiKeys now lives on every
  # agent-flavor Kind (`Ezagent.Entity.Agent` / `Ezagent.Entity.CurlAgent`
  # / `Ezagent.Entity.Echo` — `type_name` varies per flavor:
  # `:agent` / `:curl_agent` / `:echo`). Per the
  # `feedback_register_lookup_key_parity` convention the cap shape uses
  # `:any` for the kind axis so a single cap declaration matches every
  # flavor (Lifecycle / Routing / Presence follow the same pattern when
  # cross-Kind). The kind axis is fixed at registration via
  # `kind_module.type_name()` in `cap_for_action/3`; using `:any` here
  # widens what a granted cap matches but the registration site still
  # bounds WHICH Kinds can dispatch this Behavior.
  @impl Ezagent.Behavior
  def required_caps do
    %{
      list_api_keys: Ezagent.Capability.cap(:any, __MODULE__, :list_api_keys),
      put_api_key: Ezagent.Capability.cap(:any, __MODULE__, :put_api_key),
      delete_api_key: Ezagent.Capability.cap(:any, __MODULE__, :delete_api_key),
      get_api_key: Ezagent.Capability.cap(:any, __MODULE__, :get_api_key)
    }
  end

  @impl Ezagent.Behavior
  def cap_subjects do
    [
      {:list_api_keys, "list the API-key slot names this agent holds (values redacted)"},
      {:put_api_key, "set or rotate an API key value for a named slot on this agent"},
      {:delete_api_key, "remove an API key slot from this agent"},
      {:get_api_key,
       "fetch the agent's API key for outbound use (sensitive — caller must hold cap)"}
    ]
  end

  @impl Ezagent.Behavior
  def state_slice, do: :api_keys

  @impl Ezagent.Behavior
  def init_slice(args) do
    %{
      keys: %{},
      # Allen 2026-05-26 — `:creator_uri` carries the entity URI that
      # created this agent (passed via `instantiate` args). Used by
      # `data_owner/1` so `default_grants_from_data_owner/2` grants the
      # creator the right to view / rotate / delete this agent's keys.
      # Mirrors the `Behavior.Chat.init_slice/1` `:owner_uri` pattern
      # (PR-OWN-2). `nil` for agents spawned without a creator arg
      # (system / test paths) — those fall back to `:no_owner` in
      # `data_owner/1`, so only the bootstrap admin can grant.
      creator_uri: Map.get(args, :creator_uri)
    }
  end

  @impl Ezagent.Behavior
  def invoke(:list_api_keys, slice, _args, _ctx) do
    listing =
      slice.keys
      |> Enum.map(fn {provider, key} -> %{provider: provider, masked: mask(key)} end)
      |> Enum.sort_by(& &1.provider)

    {:ok, slice, %{api_keys: listing}}
  end

  def invoke(:put_api_key, slice, %{provider: provider, key: key}, _ctx)
      when is_binary(provider) and is_binary(key) and provider != "" and key != "" do
    new_slice = %{slice | keys: Map.put(slice.keys, provider, key)}
    {:ok, new_slice, %{ok: true, provider: provider}}
  end

  def invoke(:delete_api_key, slice, %{provider: provider}, _ctx)
      when is_binary(provider) do
    new_slice = %{slice | keys: Map.delete(slice.keys, provider)}
    {:ok, new_slice, %{ok: true, provider: provider}}
  end

  def invoke(:get_api_key, slice, %{provider: provider}, _ctx)
      when is_binary(provider) do
    case Map.fetch(slice.keys, provider) do
      {:ok, key} -> {:ok, slice, %{key: key, provider: provider}}
      :error -> {:error, {:no_api_key, provider}}
    end
  end

  @impl Ezagent.Behavior
  def interface do
    %{
      list_api_keys: %{
        description: "List the agent's stored API keys with masked values",
        args: %{},
        returns: %{api_keys: {:list, :map}},
        modes: [:call]
      },
      put_api_key: %{
        description: "Store or replace the agent's API key for a provider",
        args: %{provider: :string, key: :string},
        returns: %{ok: :boolean, provider: :string},
        modes: [:call]
      },
      delete_api_key: %{
        description: "Delete the agent's API key for a provider",
        args: %{provider: :string},
        returns: %{ok: :boolean, provider: :string},
        modes: [:call]
      },
      get_api_key: %{
        description: "Fetch the agent's plaintext API key for a provider",
        args: %{provider: :string},
        returns: %{key: :string, provider: :string},
        modes: [:call]
      }
    }
  end

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

  # Allen 2026-05-26 — agent-Kind ApiKeys data_owner reads
  # `:creator_uri` from the live `:api_keys` slice (durable via
  # `{:snapshot, :on_change}` on Agent Kind). Mirrors the
  # `Behavior.Chat.data_owner/1` pattern (PR-OWN-2 §6) which reads
  # session's `:owner_uri` from the `:chat` slice.
  #
  # Three resolution outcomes:
  #
  #  - `%URI{}` — the agent has a recorded creator; THAT URI is the
  #    data owner and receives `default_grants_from_data_owner/2`'s
  #    grant when the agent spawns.
  #  - `:no_owner` — agent spawned without `:creator_uri` (system /
  #    test paths) OR the Kind isn't live yet (pre-spawn lookup); only
  #    bootstrap admin can grant.
  #  - `:any` — sentinel used by `default_grants_from_data_owner/2`
  #    for catalog-wide enumeration.
  @impl Ezagent.Behavior
  def data_owner(%URI{scheme: "entity", host: "agent"} = agent_uri) do
    case Ezagent.Kind.get_slice(agent_uri, :api_keys) do
      {:ok, %{creator_uri: %URI{} = creator}} -> creator
      _ -> :no_owner
    end
  end

  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner
end
