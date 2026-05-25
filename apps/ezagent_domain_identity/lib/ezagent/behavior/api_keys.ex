defmodule Ezagent.Behavior.ApiKeys do
  @moduledoc """
  ApiKeys Behavior — per-User secret storage for outbound API
  credentials (DeepSeek, OpenAI, Anthropic, etc.).

  Slice shape:

      %{keys: %{provider :: String.t() => key :: String.t()}}

  ## Why on User Kind (not a separate Credentials Kind)

  Each user owns their own keys. Persisting on User leverages the
  existing `{:snapshot, :on_change}` policy — keys survive phx
  restart automatically, no new persistence machinery needed.

  ## Why not in a global keystore

  Allen 2026-05-19: "系统本身不提供 api-key" — every user supplies
  their own. Putting keys on User makes "whose key?" obvious from
  dispatch ctx.caller.

  ## Caps

  - `identity:api_keys:write` — required for :put_api_key / :delete_api_key.
    Granted by default for self-target (caller_uri == target_user_uri);
    admin always has it.
  - `identity:api_keys:read` — required for :get_api_key (callers like
    CurlAgent need this to fetch the user's key at dispatch time).
    Granted by default for self-target; admin always has it.

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

  @impl Ezagent.Behavior
  def cap_subjects do
    [
      {:list_api_keys, "list the API-key slot names this Kind owns (values redacted)"},
      {:put_api_key, "set or rotate an API key value for a named slot"},
      {:delete_api_key, "remove an API key slot entirely"},
      {:get_api_key, "fetch an API key value for outbound use (sensitive — caller must hold cap)"}
    ]
  end

  @impl Ezagent.Behavior
  def state_slice, do: :api_keys

  @impl Ezagent.Behavior
  def init_slice(_args), do: %{keys: %{}}

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
        description: "List the user's stored API keys with masked values",
        args: %{},
        returns: %{api_keys: {:list, :map}},
        modes: [:call]
      },
      put_api_key: %{
        description: "Store or replace the user's API key for a provider",
        args: %{provider: :string, key: :string},
        returns: %{ok: :boolean, provider: :string},
        modes: [:call]
      },
      delete_api_key: %{
        description: "Delete the user's API key for a provider",
        args: %{provider: :string},
        returns: %{ok: :boolean, provider: :string},
        modes: [:call]
      },
      get_api_key: %{
        description: "Fetch the user's plaintext API key for a provider",
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

  # PR-OWN-4 (caps-data-ownership SPEC #306 §6): per-entity Behavior
  # — the entity (user / agent) owns its own state for this Behavior.
  @impl Ezagent.Behavior
  def data_owner(%URI{} = entity_uri), do: Ezagent.URI.instance(entity_uri)
  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner

end
