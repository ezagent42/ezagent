# Provider Credential Sealed-Envelope Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give provider plugins one shared, already-proven way to seal secrets at rest, then make Forgejo credentials durable with it — so a single process crash stops wiping every user's Forgejo authorization.

**Architecture:** `Ezagent.ProviderConnection.SealedEnvelope` is extracted from the two parallel implementations already inside `local_authorization_backend` (`exchange.ex` and `reconciliation.ex` each carry a full copy of key-snapshot loading, fingerprinting, seal and unseal). It keeps their exact envelope — `{key_id, key_fingerprint, nonce, ciphertext}`, AES-256-GCM, tag-prepended, AAD bound to a `purpose` — and their exact keyring (`AuthorizationKeyRing`). Forgejo then stores credentials in a per-tenant table sealed by that module, replacing its own ETS table and its own AES code.

**Tech Stack:** Elixir 1.19 / OTP 28, Ecto + Postgres, `:crypto` AES-256-GCM, ExUnit.

## Global Constraints

- Run every `mix` command from the umbrella root, never from inside an app directory — `cd apps/<app> && mix test` loads only that app's deps and produces fake `UndefinedFunctionError`s.
- Postgres on this machine is port **15432**. Every test command needs `MIX_ENV=test POSTGRES_PORT=15432`.
- `mix ci.fast` is the mandatory gate before every commit. Run it with an explicit long timeout (`timeout: 600000`). **A killed or timed-out run is NOT a pass.**
- Format only touched files: `mix format <paths>`. Never run a repo-wide `mix format`.
- Assertive access only: destructure in function heads (`def f(%{k: v})`), never `arg.k` on a value the compiler cannot see through. `PluginWorkspaceLocalityContractTest` enumerates `:unknown_value.<field>/0` and will fail the gate.
- Do NOT widen, freeze, or add baseline entries to any CI gate. Fix the code instead. `# uri-canonical-allow: <reason>` and `# arch-cap-bump: <reason>` exist but require a specific written reason.
- Per-tenant DB tables MUST carry `workspace_uri` NOT NULL and be declared in `apps/ezagent_core/test/invariants/per_tenant_tables_have_workspace_column_test.exs`.
- Migrations live in `apps/ezagent_core/priv/repo_pg/migrations/` regardless of which app owns the table.
- New umbrella apps must be listed in `apps/ezagent_web/mix.exs` deps. (No new apps in this plan — noted so nobody adds one.)

## Baseline test reality — read before judging any result

Two suites in scope are **flaky at the branch anchor**, verified by repeated runs on `c4ec7b478`:

| Suite | Anchor behaviour | Usable as a verdict? |
|---|---|---|
| `apps/ezagent_domain_provider_connection/test` minus `application_test.exs` (325 tests) | stable green | **Yes — this is the guard net for PR-1** |
| `apps/ezagent_domain_provider_connection/test/ezagent_domain_provider_connection/application_test.exs` (6 tests) | **0 / 3 / 4 failures across three runs at the anchor** | **No.** Node-global teardown aggressors (#189): each passes alone, they poison each other in one BEAM |
| `apps/ezagent_plugin_github/test` | intermittent single failure (~1 in 5 runs) | Treat a single failure as noise; re-run |

Every seal/unseal call site touched by PR-1 is covered by the stable 325. So the guard net is valid for what this plan changes — but **do not claim "the domain suite is green"**, and never use `application_test.exs` to decide whether a change broke something.

---

## File Structure

**PR-1 — extract the envelope (domain, pure refactor):**

| File | Responsibility |
|---|---|
| `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/sealed_envelope.ex` | **Create.** The only sealing implementation: key snapshot from `AuthorizationKeyRing` config, `seal/4`, `open/4`. Purpose-parameterised; enforces nothing about which purposes exist. |
| `.../local_authorization_backend/exchange.ex` | **Modify.** Delete its 9 private crypto functions; call `SealedEnvelope`. Keep every call site's own arguments unchanged. |
| `.../local_authorization_backend/reconciliation.ex` | **Modify.** Delete its 9 private crypto functions; call `SealedEnvelope`. **Keep its purpose allowlist at the call site** — see Task 3. |
| `apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/sealed_envelope_test.exs` | **Create.** Includes the byte-compatibility golden vector. |

**PR-2 — Forgejo credentials become durable (plugin, stacked on PR-1):**

| File | Responsibility |
|---|---|
| `apps/ezagent_core/priv/repo_pg/migrations/20260730120000_create_forgejo_credentials.exs` | **Create.** Per-tenant table, envelope columns. |
| `apps/ezagent_plugin_forgejo/lib/ezagent_plugin_forgejo/credential_record.ex` | **Create.** Ecto schema + the durable read/write/CAS the backend needs. |
| `apps/ezagent_plugin_forgejo/lib/ezagent_plugin_forgejo/forgejo_credential_backend.ex` | **Modify.** ETS → `CredentialRecord`; `Sealed` → `SealedEnvelope`. |
| `apps/ezagent_plugin_forgejo/lib/ezagent_plugin_forgejo/oauth_app.ex` | **Modify.** `Sealed` → `SealedEnvelope`; gains `key_id` / `key_fingerprint`. |
| `apps/ezagent_plugin_forgejo/lib/ezagent_plugin_forgejo/sealed.ex` | **Delete.** |
| `config/config.exs` | **Modify.** Remove `:ezagent_plugin_forgejo, :token_encryption_key` (one keyring now). |

---

## PR-1 — Extract `SealedEnvelope`

### Task 1: `SealedEnvelope` with a byte-compatibility golden vector

**Files:**
- Create: `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/sealed_envelope.ex`
- Test: `apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/sealed_envelope_test.exs`

**Interfaces:**
- Consumes: `Ezagent.ProviderConnection.AuthorizationKeyRing.validated_fingerprint/0`, `Ezagent.ProviderConnection.LocalAuthorizationBackend.Support.sha256/1`, `.../Support.encode_aad/2`.
- Produces, relied on by Tasks 2, 3 and all of PR-2:
  - `snapshot() :: {:ok, %{active_key_id: String.t(), keys: %{String.t() => binary()}}} | {:error, :authorization_backend_unavailable}`
  - `seal(snapshot, key_id_or_active, purpose, value, aad) :: %{key_id: String.t(), key_fingerprint: binary(), nonce: binary(), ciphertext: binary()}` where `key_id_or_active` is `:active` or a binary key id
  - `seal_with_record_key(snapshot, %{key_id: String.t(), key_fingerprint: binary()}, purpose, value, aad) :: {:ok, envelope} | {:error, :authentication_failed}`
  - `open(snapshot, purpose, envelope, aad) :: {:ok, term()} | {:error, :authentication_failed}`

- [ ] **Step 1: Write the golden-vector test first**

The point of this test: the refactor moves cryptography. "The call sites' tests still pass" does **not** prove byte compatibility, because those tests seal and unseal with the same code — they would pass even if the tag moved or the AAD encoding changed, while every existing DB row became unopenable. So this test builds an envelope with `:crypto` **directly**, transcribed from the pre-refactor source, and requires `open/4` to read it.

Create `apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/sealed_envelope_test.exs`:

```elixir
defmodule Ezagent.ProviderConnection.SealedEnvelopeTest do
  @moduledoc """
  Byte-compatibility is the whole point of this file.

  `SealedEnvelope` was extracted from private functions in `exchange.ex` and
  `reconciliation.ex`. Rows sealed by that pre-extraction code exist, so the
  extracted module must open them. A round-trip test cannot show that: it seals
  and opens with the same code and stays green even if the tag position or the
  AAD encoding changed. The golden vector below is therefore built with
  `:crypto` directly, transcribed from the pre-extraction source.
  """
  use ExUnit.Case, async: false

  alias Ezagent.ProviderConnection.LocalAuthorizationBackend.Support
  alias Ezagent.ProviderConnection.SealedEnvelope

  @purpose :authorization_attempt
  @aad %{connection_id: "conn-1", correlation_id: "corr-1"}

  setup do
    {:ok, snapshot} = SealedEnvelope.snapshot()
    {:ok, snapshot: snapshot}
  end

  # Transcribed from the pre-extraction `seal_with/5`: nonce 12 bytes,
  # plaintext = term_to_binary(value, [:deterministic]), AAD =
  # Support.encode_aad(purpose, aad), ciphertext = <<tag, ciphertext>>.
  defp legacy_seal(snapshot, purpose, value, aad) do
    key_id = snapshot.active_key_id
    key = Map.fetch!(snapshot.keys, key_id)
    nonce = :crypto.strong_rand_bytes(12)
    plaintext = :erlang.term_to_binary(value, [:deterministic])

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        key,
        nonce,
        plaintext,
        Support.encode_aad(purpose, aad),
        true
      )

    %{
      key_id: key_id,
      key_fingerprint: Support.sha256(key),
      nonce: nonce,
      ciphertext: <<tag::binary, ciphertext::binary>>
    }
  end

  test "opens an envelope sealed by the pre-extraction algorithm", %{snapshot: snapshot} do
    value = %{state: "st-1", pkce_verifier: "verifier-1"}
    envelope = legacy_seal(snapshot, @purpose, value, @aad)

    assert {:ok, ^value} = SealedEnvelope.open(snapshot, @purpose, envelope, @aad)
  end

  test "its own output is byte-identical in shape to the legacy envelope", %{snapshot: snapshot} do
    value = %{state: "st-2"}
    legacy = legacy_seal(snapshot, @purpose, value, @aad)
    fresh = SealedEnvelope.seal(snapshot, :active, @purpose, value, @aad)

    assert Map.keys(fresh) |> Enum.sort() == Map.keys(legacy) |> Enum.sort()
    assert fresh.key_id == legacy.key_id
    assert fresh.key_fingerprint == legacy.key_fingerprint
    assert byte_size(fresh.nonce) == byte_size(legacy.nonce)
    # Same plaintext + same tag length => same ciphertext length. A moved tag or
    # a changed plaintext encoding shows up here.
    assert byte_size(fresh.ciphertext) == byte_size(legacy.ciphertext)
  end

  test "the legacy algorithm opens what SealedEnvelope sealed", %{snapshot: snapshot} do
    value = %{round: :trip}
    %{key_id: key_id, nonce: nonce, ciphertext: blob} =
      SealedEnvelope.seal(snapshot, :active, @purpose, value, @aad)

    key = Map.fetch!(snapshot.keys, key_id)
    <<tag::binary-size(16), ciphertext::binary>> = blob

    plaintext =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        key,
        nonce,
        ciphertext,
        Support.encode_aad(@purpose, @aad),
        tag,
        false
      )

    assert :erlang.binary_to_term(plaintext, [:safe]) == value
  end

  # AAD binds a ciphertext to its purpose AND its record. Without this, a
  # credential envelope could be opened as an authorization attempt.
  test "a different purpose cannot open it", %{snapshot: snapshot} do
    envelope = SealedEnvelope.seal(snapshot, :active, @purpose, %{a: 1}, @aad)

    assert {:error, :authentication_failed} =
             SealedEnvelope.open(snapshot, :credential_handoff, envelope, @aad)
  end

  test "a different aad cannot open it", %{snapshot: snapshot} do
    envelope = SealedEnvelope.seal(snapshot, :active, @purpose, %{a: 1}, @aad)

    assert {:error, :authentication_failed} =
             SealedEnvelope.open(snapshot, @purpose, envelope, %{connection_id: "other"})
  end

  test "a wrong key fingerprint is refused before decryption", %{snapshot: snapshot} do
    envelope = SealedEnvelope.seal(snapshot, :active, @purpose, %{a: 1}, @aad)
    tampered = %{envelope | key_fingerprint: :crypto.hash(:sha256, "not-the-key")}

    assert {:error, :authentication_failed} =
             SealedEnvelope.open(snapshot, @purpose, tampered, @aad)
  end

  test "a malformed envelope is refused, not raised", %{snapshot: snapshot} do
    for bad <- [%{}, %{key_id: "x"}, "not-a-map", nil] do
      assert {:error, :authentication_failed} =
               SealedEnvelope.open(snapshot, @purpose, bad, @aad)
    end
  end

  test "seal_with_record_key refuses a row whose fingerprint does not match", %{
    snapshot: snapshot
  } do
    row = %{key_id: snapshot.active_key_id, key_fingerprint: :crypto.hash(:sha256, "wrong")}

    assert {:error, :authentication_failed} =
             SealedEnvelope.seal_with_record_key(snapshot, row, @purpose, %{a: 1}, @aad)
  end

  test "seal_with_record_key seals under the row's key when it matches", %{snapshot: snapshot} do
    key = Map.fetch!(snapshot.keys, snapshot.active_key_id)
    row = %{key_id: snapshot.active_key_id, key_fingerprint: Support.sha256(key)}

    assert {:ok, envelope} =
             SealedEnvelope.seal_with_record_key(snapshot, row, @purpose, %{a: 1}, @aad)

    assert envelope.key_id == snapshot.active_key_id
    assert {:ok, %{a: 1}} = SealedEnvelope.open(snapshot, @purpose, envelope, @aad)
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
MIX_ENV=test POSTGRES_PORT=15432 mix test \
  apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/sealed_envelope_test.exs
```

Expected: every test FAILS with `Ezagent.ProviderConnection.SealedEnvelope is not available` / `function SealedEnvelope.snapshot/0 is undefined`.

- [ ] **Step 3: Create the module**

Transcribe the algorithm — do not redesign it. `@key_id_pattern`, the 32-byte key check, the duplicate-id check, the fingerprint algorithm and the `@fixture_enabled` test source all come from `exchange.ex` verbatim.

Create `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/sealed_envelope.ex`:

```elixir
defmodule Ezagent.ProviderConnection.SealedEnvelope do
  @moduledoc """
  The single at-rest sealing implementation for this domain and its provider
  plugins: AES-256-GCM under a keyed, rotatable envelope.

      %{key_id: String.t(), key_fingerprint: binary(), nonce: binary(), ciphertext: binary()}

  Extracted verbatim from private functions that existed in TWO full parallel
  copies inside `LocalAuthorizationBackend` (`exchange.ex` and
  `reconciliation.ex` each carried snapshot loading, fingerprinting, seal and
  unseal). The algorithm is unchanged — rows sealed before the extraction must
  still open, which `sealed_envelope_test.exs` proves with a golden vector built
  from `:crypto` directly rather than by round-tripping this module against
  itself.

  ## Rotation is real

  A snapshot carries EVERY configured key plus which one is active. New rows
  seal under `:active`; existing rows open under the `key_id` they recorded. So
  rotation is "add a key, make it active" and old ciphertext keeps opening —
  it does not orphan anything.

  ## `purpose` is what keeps uses apart

  `purpose` and a record-specific `aad` are bound into the GCM additional data.
  A ciphertext sealed for one purpose cannot be opened as another, and cannot be
  moved between records. Purposes are not registered anywhere: they are atoms
  chosen by the caller. Existing ones are `:authorization_attempt`,
  `:authorization_callback` and `:credential_handoff`.

  **This module does not police which purposes a caller may open.** The recovery
  path in `reconciliation.ex` deliberately restricts itself to the two
  authorization purposes; that restriction is a property of that path, so it
  stays at that call site rather than being centralised here where it would
  either leak to callers that must not have it or be silently dropped.

  ## The keyring name is historical

  Keys come from `Application.get_env(:ezagent_domain_provider_connection,
  AuthorizationKeyRing)` and are cross-checked against
  `AuthorizationKeyRing.validated_fingerprint/0`. That name predates this module
  serving anything other than authorization records; it is shared, and it is not
  renamed here because the env var (`EZAGENT_PROVIDER_AUTH_ACTIVE_KEY_ID`) is
  deployment-visible and renaming it buys no behaviour.
  """

  alias Ezagent.ProviderConnection.AuthorizationKeyRing
  alias Ezagent.ProviderConnection.LocalAuthorizationBackend.Support

  @tag_bytes 16
  @nonce_bytes 12
  @key_bytes 32
  @key_id_pattern ~r/\A[a-zA-Z0-9._-]{1,64}\z/

  @fixture_enabled Application.compile_env(
                     :ezagent_domain_provider_connection,
                     :authorization_key_ring_fixture_enabled,
                     false
                   )

  @type snapshot :: %{active_key_id: String.t(), keys: %{String.t() => binary()}}
  @type envelope :: %{
          key_id: String.t(),
          key_fingerprint: binary(),
          nonce: binary(),
          ciphertext: binary()
        }

  @doc """
  Loads and validates the key snapshot.

  Fails closed as `:authorization_backend_unavailable` on any malformed
  configuration, and only after the computed fingerprint matches the singleton's
  validated one — so a process reading a config that drifted from what the
  keyring validated at boot cannot seal or open anything.
  """
  @spec snapshot() :: {:ok, snapshot()} | {:error, :authorization_backend_unavailable}
  def snapshot do
    with {:ok, state} <- parse_config(),
         {:ok, validated} <- AuthorizationKeyRing.validated_fingerprint(),
         true <- fingerprint(state) == validated do
      {:ok, state}
    else
      _error -> {:error, :authorization_backend_unavailable}
    end
  end

  @doc "Seals a term under the active key, or under an explicitly named key."
  @spec seal(snapshot(), :active | String.t(), atom(), term(), term()) :: envelope()
  def seal(snapshot, :active, purpose, value, aad),
    do: seal(snapshot, snapshot.active_key_id, purpose, value, aad)

  def seal(%{keys: keys}, key_id, purpose, value, aad) when is_binary(key_id) do
    key = Map.fetch!(keys, key_id)
    nonce = :crypto.strong_rand_bytes(@nonce_bytes)
    plaintext = :erlang.term_to_binary(value, [:deterministic])

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        key,
        nonce,
        plaintext,
        Support.encode_aad(purpose, aad),
        true
      )

    %{
      key_id: key_id,
      key_fingerprint: Support.sha256(key),
      nonce: nonce,
      ciphertext: <<tag::binary, ciphertext::binary>>
    }
  end

  @doc """
  Re-seals under the key an existing row already used.

  Used when a record must keep its key across an update instead of migrating to
  whatever is active now. Refuses if the row's recorded fingerprint does not
  match the key that id resolves to — that mismatch means the configuration
  changed under a live row, and sealing anyway would produce a row nothing can
  open.
  """
  @spec seal_with_record_key(
          snapshot(),
          %{key_id: String.t(), key_fingerprint: binary()},
          atom(),
          term(),
          term()
        ) :: {:ok, envelope()} | {:error, :authentication_failed}
  def seal_with_record_key(
        %{keys: keys} = snapshot,
        %{key_id: key_id, key_fingerprint: fingerprint},
        purpose,
        value,
        aad
      ) do
    with {:ok, key} <- Map.fetch(keys, key_id),
         true <- Support.sha256(key) == fingerprint do
      {:ok, seal(snapshot, key_id, purpose, value, aad)}
    else
      _error -> {:error, :authentication_failed}
    end
  end

  def seal_with_record_key(_snapshot, _row, _purpose, _value, _aad),
    do: {:error, :authentication_failed}

  @doc """
  Opens an envelope, requiring the recorded fingerprint AND the GCM tag to verify.

  Every failure — unknown key id, fingerprint mismatch, wrong purpose, wrong
  aad, tampered ciphertext, malformed shape — is the same
  `:authentication_failed`. Callers must not be able to tell which, and this
  never raises: a malformed row is a closed error, not a crash in whatever
  process happened to read it.
  """
  @spec open(snapshot(), atom(), term(), term()) ::
          {:ok, term()} | {:error, :authentication_failed}
  def open(
        %{keys: keys},
        purpose,
        %{key_id: key_id, key_fingerprint: fingerprint, nonce: nonce, ciphertext: blob},
        aad
      )
      when is_binary(key_id) and is_binary(fingerprint) and is_binary(nonce) and
             byte_size(nonce) == @nonce_bytes and is_binary(blob) and
             byte_size(blob) >= @tag_bytes do
    with {:ok, key} <- Map.fetch(keys, key_id),
         true <- Support.sha256(key) == fingerprint do
      <<tag::binary-size(@tag_bytes), ciphertext::binary>> = blob

      case :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             nonce,
             ciphertext,
             Support.encode_aad(purpose, aad),
             tag,
             false
           ) do
        :error -> {:error, :authentication_failed}
        plaintext -> {:ok, :erlang.binary_to_term(plaintext, [:safe])}
      end
    else
      _error -> {:error, :authentication_failed}
    end
  rescue
    _error -> {:error, :authentication_failed}
  end

  def open(_snapshot, _purpose, _envelope, _aad), do: {:error, :authentication_failed}

  # ── config ───────────────────────────────────────────────────────────

  defp parse_config do
    config = Application.get_env(:ezagent_domain_provider_connection, AuthorizationKeyRing, [])

    with {:ok, pairs} <- key_pairs(Keyword.get(config, :source), config),
         {:ok, keys} <- validate_keys(pairs),
         active when is_binary(active) <- Keyword.get(config, :active_key_id),
         true <- Regex.match?(@key_id_pattern, active),
         true <- Map.has_key?(keys, active) do
      {:ok, %{active_key_id: active, keys: keys}}
    else
      _error -> {:error, :authorization_backend_unavailable}
    end
  end

  if @fixture_enabled do
    defp key_pairs(:explicit_test, config) do
      case Keyword.get(config, :keys) do
        keys when is_map(keys) -> {:ok, Map.to_list(keys)}
        _other -> {:error, :invalid}
      end
    end
  end

  defp key_pairs(:runtime_env, config) do
    with json when is_binary(json) <- Keyword.get(config, :keys_json),
         {:ok, %Jason.OrderedObject{values: pairs}} <-
           Jason.decode(json, objects: :ordered_objects) do
      Enum.reduce_while(pairs, {:ok, []}, fn {id, encoded}, {:ok, acc} ->
        case is_binary(encoded) && Base.decode64(encoded) do
          {:ok, key} -> {:cont, {:ok, [{id, key} | acc]}}
          _other -> {:halt, {:error, :invalid}}
        end
      end)
    else
      _error -> {:error, :invalid}
    end
  end

  defp key_pairs(_source, _config), do: {:error, :invalid}

  defp validate_keys(pairs) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn {id, key}, {:ok, acc} ->
      if is_binary(id) and Regex.match?(@key_id_pattern, id) and is_binary(key) and
           byte_size(key) == @key_bytes and not Map.has_key?(acc, id) do
        {:cont, {:ok, Map.put(acc, id, key)}}
      else
        {:halt, {:error, :invalid}}
      end
    end)
  end

  defp fingerprint(%{active_key_id: active, keys: keys}) do
    key_digests = Map.new(keys, fn {id, key} -> {id, Support.sha256(key)} end)
    Support.sha256(:erlang.term_to_binary({active, key_digests}, [:deterministic]))
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
MIX_ENV=test POSTGRES_PORT=15432 mix test \
  apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/sealed_envelope_test.exs
```

Expected: `11 tests, 0 failures`.

- [ ] **Step 5: Run the stable guard net and the gate**

```bash
FILES=$(find apps/ezagent_domain_provider_connection/test -name "*_test.exs" ! -name "application_test.exs" | tr '\n' ' ')
MIX_ENV=test POSTGRES_PORT=15432 mix test $FILES
MIX_ENV=test POSTGRES_PORT=15432 mix ci.fast
```

Expected: `325 tests, 0 failures` (plus the 11 new = `336 tests, 0 failures`) and `ci.fast` EXIT=0. If `ci.fast` reports `PluginWorkspaceLocalityContractTest` hits in the new module, convert the offending `x.field` to head destructuring — do not touch the baseline.

- [ ] **Step 6: Commit**

```bash
mix format apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/sealed_envelope.ex \
  apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/sealed_envelope_test.exs
git add apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/sealed_envelope.ex \
  apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/sealed_envelope_test.exs
git commit -m "feat(provider-connection): SealedEnvelope — one keyed at-rest sealing implementation

Extracted verbatim from two full parallel copies inside LocalAuthorizationBackend.
No call site switched yet; exchange.ex and reconciliation.ex still use their own
copies, so this commit changes no behaviour.

The golden-vector test is the load-bearing part: it builds an envelope with
:crypto directly, transcribed from the pre-extraction source, and requires
open/4 to read it. A round-trip test could not show byte compatibility — it
seals and opens with the same code and stays green even if the tag moved.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Switch `exchange.ex` to `SealedEnvelope`

**Files:**
- Modify: `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/local_authorization_backend/exchange.ex`

**Interfaces:**
- Consumes: `SealedEnvelope.snapshot/0`, `seal/5`, `seal_with_record_key/5`, `open/4` (Task 1).
- Produces: nothing new. Every existing private caller keeps its arguments.

Call sites to rewrite (line numbers from the pre-change file; find by name, they will shift):

| Old private call | Becomes |
|---|---|
| `crypto_state()` — 1 site (`:904`) | `SealedEnvelope.snapshot()` |
| `seal_with(snapshot, :active, purpose, value, aad)` — `:118 :246 :399 :494` | `SealedEnvelope.seal(snapshot, :active, purpose, value, aad)` |
| `seal_with_record_key(snapshot, row, purpose, value, aad)` — `:335` | `SealedEnvelope.seal_with_record_key(...)` |
| `unseal_with(snapshot, purpose, envelope, aad)` — `:163 :209 :310 :415 :457 :464` | `SealedEnvelope.open(snapshot, purpose, envelope, aad)` |

Then delete these private functions and the attributes only they used: `crypto_state/0`, `parse_crypto_config/0`, `crypto_pairs/2` (all clauses), `crypto_keys/1`, `crypto_fingerprint/1`, `seal_with/5` (both clauses), `seal_with_record_key/5`, `unseal_with/4` (both clauses), plus `@tag_bytes`, `@key_id_pattern` and `@fixture_enabled` **only if no other function in the file still references them** — grep before deleting each.

- [ ] **Step 1: Add the alias and rewrite the call sites**

```elixir
# near the other aliases at the top of exchange.ex
alias Ezagent.ProviderConnection.SealedEnvelope
```

Rewrite each call site exactly as the table above. Keep argument order and values identical — this task must not change any argument.

- [ ] **Step 2: Delete the now-unused private functions**

Before deleting each attribute, prove it is unused:

```bash
D=apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/local_authorization_backend
grep -n "@tag_bytes\|@key_id_pattern\|@fixture_enabled" $D/exchange.ex
```

Expected after the rewrite: only the attribute definitions themselves appear. Delete those three, and the nine private functions listed above.

- [ ] **Step 3: Compile and check for unused warnings**

```bash
MIX_ENV=test POSTGRES_PORT=15432 mix compile --force --warnings-as-errors 2>&1 | tail -20
```

Expected: no `unused` warnings for `exchange.ex`. An `unused function` warning means a deletion was missed; an `undefined` warning means a call site was missed.

- [ ] **Step 4: Run the stable guard net**

```bash
FILES=$(find apps/ezagent_domain_provider_connection/test -name "*_test.exs" ! -name "application_test.exs" | tr '\n' ' ')
MIX_ENV=test POSTGRES_PORT=15432 mix test $FILES
```

Expected: `336 tests, 0 failures`. These 336 exercise the authorization begin/consume/refresh paths that seal and open for real, so a broken extraction fails here.

- [ ] **Step 5: Run the gate**

```bash
MIX_ENV=test POSTGRES_PORT=15432 mix ci.fast
```

Expected: EXIT=0.

- [ ] **Step 6: Commit**

```bash
mix format apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/local_authorization_backend/exchange.ex
git add apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/local_authorization_backend/exchange.ex
git commit -m "refactor(provider-connection): exchange.ex uses SealedEnvelope

Deletes its nine private crypto functions (snapshot loading, key validation,
fingerprint, seal, seal-with-record-key, unseal). Every call site keeps its
arguments; only the callee changed.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Switch `reconciliation.ex` to `SealedEnvelope`, keeping its purpose allowlist

**Files:**
- Modify: `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/local_authorization_backend/reconciliation.ex`

**Interfaces:**
- Consumes: `SealedEnvelope.snapshot/0`, `seal/5`, `open/4` (Task 1).
- Produces: nothing new.

**The one thing that must not be flattened.** `decrypt_recovery_envelope/4` wraps the unseal in

```elixir
if purpose in [:authorization_attempt, :authorization_callback] do
```

That is a deliberate restriction on the RECOVERY path: it must not be able to open a `:credential_handoff` envelope. `SealedEnvelope.open/4` has no such restriction by design (Task 1 moduledoc). So the allowlist **stays in this file**, wrapped around the call. Deleting it would silently widen what the recovery path can decrypt; moving it into `SealedEnvelope` would impose it on `exchange.ex`, which legitimately opens `:credential_handoff`.

- [ ] **Step 1: Add the alias**

```elixir
alias Ezagent.ProviderConnection.SealedEnvelope
```

- [ ] **Step 2: Rewrite `seal_recovered_handoff/3` to delegate**

Replace the whole function body — the purpose stays hardcoded here, because that is this path's contract:

```elixir
  # The purpose stays hardcoded: this path only ever re-seals a credential
  # handoff. Passing it in would let a caller choose, which this path must not.
  defp seal_recovered_handoff(snapshot, value, aad),
    do: SealedEnvelope.seal(snapshot, :active, :credential_handoff, value, aad)
```

- [ ] **Step 3: Rewrite `decrypt_recovery_envelope/4`, keeping the allowlist**

```elixir
  # The allowlist is this path's own restriction and stays here. `SealedEnvelope`
  # deliberately does not police purposes (it serves callers that legitimately
  # open `:credential_handoff`), so centralising this would widen the recovery
  # path; deleting it would let recovery decrypt credential handoffs.
  @recovery_purposes [:authorization_attempt, :authorization_callback]

  defp decrypt_recovery_envelope(snapshot, purpose, envelope, aad) do
    if purpose in @recovery_purposes do
      SealedEnvelope.open(snapshot, purpose, envelope, aad)
    else
      {:error, :authentication_failed}
    end
  end
```

- [ ] **Step 4: Rewrite `recovery_crypto_state/0` and delete its config parsing**

```elixir
  defp recovery_crypto_state, do: SealedEnvelope.snapshot()
```

Then delete: `parse_recovery_crypto_config/0`, `load_recovery_keys/2` (all clauses), `validate_recovery_keys/1`, `valid_recovery_key_id?/1`, `decode_recovery_key/1` (all clauses), `recovery_crypto_fingerprint/1`, and `@tag_bytes` / `@key_id_pattern` / `@fixture_enabled` **only if unreferenced elsewhere in the file**:

```bash
D=apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/local_authorization_backend
grep -n "@tag_bytes\|@key_id_pattern\|@fixture_enabled" $D/reconciliation.ex
```

- [ ] **Step 5: Add a test pinning the recovery allowlist**

This restriction now lives in one `if` and nothing tested it. Append to `apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/sealed_envelope_test.exs`:

```elixir
defmodule Ezagent.ProviderConnection.RecoveryPurposeBoundaryTest do
  @moduledoc """
  The recovery path restricts which purposes it will decrypt. That restriction
  is one `if` in `reconciliation.ex` and is invisible to the envelope module,
  which deliberately polices nothing — so it needs its own test, or extracting
  the crypto silently widened what recovery can read.
  """
  use ExUnit.Case, async: false

  alias Ezagent.ProviderConnection.SealedEnvelope

  test "SealedEnvelope itself does NOT restrict purposes" do
    {:ok, snapshot} = SealedEnvelope.snapshot()
    aad = %{r: 1}
    envelope = SealedEnvelope.seal(snapshot, :active, :credential_handoff, %{v: 1}, aad)

    # If this ever starts failing, someone centralised the recovery allowlist
    # and broke `exchange.ex`, which legitimately opens this purpose.
    assert {:ok, %{v: 1}} = SealedEnvelope.open(snapshot, :credential_handoff, envelope, aad)
  end
end
```

- [ ] **Step 6: Compile, run the guard net, run the gate**

```bash
MIX_ENV=test POSTGRES_PORT=15432 mix compile --force --warnings-as-errors 2>&1 | tail -20
FILES=$(find apps/ezagent_domain_provider_connection/test -name "*_test.exs" ! -name "application_test.exs" | tr '\n' ' ')
MIX_ENV=test POSTGRES_PORT=15432 mix test $FILES
MIX_ENV=test POSTGRES_PORT=15432 mix ci.fast
```

Expected: no unused/undefined warnings, `337 tests, 0 failures`, `ci.fast` EXIT=0.

- [ ] **Step 7: Verify the aggressor file separately and record what you see**

```bash
for i in 1 2 3; do
  MIX_ENV=test POSTGRES_PORT=15432 mix ci.shard.domain_provider_connection_lifecycle 2>&1 \
    | grep -oE "[0-9]+ tests?, [0-9]+ failure[s]?" | tail -1
done
```

Expected: a varying count (0–4 failures). **This is the documented anchor baseline, not a verdict.** Record the three numbers in the commit message. If a number exceeds 4, or a failure names something other than `RegistryOwner` / `:registry_not_ready` / a missing ETS table, stop and investigate — that would be new.

- [ ] **Step 8: Commit**

```bash
mix format apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/local_authorization_backend/reconciliation.ex \
  apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/sealed_envelope_test.exs
git add apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/local_authorization_backend/reconciliation.ex \
  apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/sealed_envelope_test.exs
git commit -m "refactor(provider-connection): reconciliation.ex uses SealedEnvelope

Deletes its second full copy of the crypto (snapshot loading, key validation,
fingerprint, seal, unseal) — the domain carried two.

The recovery purpose allowlist STAYS here, now as @recovery_purposes around the
call. It is this path's restriction: recovery must not decrypt a credential
handoff, while exchange.ex legitimately does. Centralising it would widen
recovery; deleting it would break the boundary. Added a test pinning that
SealedEnvelope itself polices nothing, so a future centralisation fails loudly.

domain_provider_connection_lifecycle across three runs: <a> / <b> / <c> failures
— the anchor c4ec7b478 gives 0/3/4 for the same leg (node-global teardown
aggressors, #189). Not a verdict on this change; the guard net is the 337
stable tests.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## PR-2 — Forgejo credentials become durable

> Branch from the tip of PR-1. PR-2 cannot land first: it consumes `SealedEnvelope`.

### Task 4: `forgejo_credentials` table + `CredentialRecord`

**Files:**
- Create: `apps/ezagent_core/priv/repo_pg/migrations/20260730120000_create_forgejo_credentials.exs`
- Create: `apps/ezagent_plugin_forgejo/lib/ezagent_plugin_forgejo/credential_record.ex`
- Modify: `apps/ezagent_core/test/invariants/per_tenant_tables_have_workspace_column_test.exs`
- Test: `apps/ezagent_plugin_forgejo/test/ezagent_plugin_forgejo/credential_record_test.exs`

**Interfaces:**
- Consumes: `SealedEnvelope.snapshot/0`, `seal/5`, `open/4` (Task 1).
- Produces, relied on by Task 5:
  - `insert(workspace_uri :: String.t(), credential :: String.t()) :: {:ok, %{credential_ref: String.t(), credential_version: pos_integer()}} | {:error, atom()}`
  - `fetch_credential(credential_ref :: String.t()) :: {:ok, String.t()} | {:error, atom()}`
  - `version(credential_ref :: String.t()) :: {:ok, pos_integer()} | {:error, :credential_conflict}`
  - `replace(credential_ref :: String.t(), credential :: String.t(), expected_version :: pos_integer()) :: {:ok, %{credential_ref: String.t(), credential_version: pos_integer()}} | {:error, :stale_version | :credential_conflict | atom()}`
  - `delete(credential_ref :: String.t()) :: :ok`

- [ ] **Step 1: Write the migration**

```elixir
defmodule EzagentCore.Repo.Migrations.CreateForgejoCredentials do
  use Ecto.Migration

  # Forgejo provider credential custody, made durable.
  #
  # Before this table the credentials lived in an ETS table owned by one Agent.
  # That table dies with its owner, so a SINGLE crash of that process wiped
  # every user's OAuth credential on the node while the durable
  # `provider_connections` rows kept pointing at them — leaving connections that
  # look active and fail on lease. Recovery was a browser re-authorization per
  # user per instance, because the refresh token was in the same wiped record.
  #
  # This matters for Forgejo in a way it does not for GitHub: a GitHub App mints
  # a fresh installation token per operation from a config-held private key, so
  # its stored token is identity-only. A Forgejo access token IS the repository
  # credential.
  #
  # Columns follow `provider_authorization_backend_records`: the sealed envelope
  # is `{key_id, key_fingerprint, nonce, ciphertext}` from
  # `Ezagent.ProviderConnection.SealedEnvelope`, which supports rotation (rows
  # open under the key they recorded).
  #
  # Per-tenant (SPEC v3 §7.4 / invariant 14): `workspace_uri` NOT NULL.
  def change do
    create table(:forgejo_credentials, primary_key: false) do
      add :credential_ref, :string, primary_key: true
      add :workspace_uri, :string, null: false
      add :credential_version, :integer, null: false, default: 1
      add :key_id, :string, null: false
      add :key_fingerprint, :binary, null: false
      add :nonce, :binary, null: false
      add :ciphertext, :binary, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:forgejo_credentials, [:workspace_uri])
  end
end
```

- [ ] **Step 2: Declare the table in the per-tenant invariant test**

In `apps/ezagent_core/test/invariants/per_tenant_tables_have_workspace_column_test.exs`, add to `@per_tenant_schemas` after the `forgejo_oauth_apps` entry:

```elixir
    # Forgejo credential custody made durable. Per-tenant: a credential belongs
    # to exactly one workspace, and `workspace_uri` is written on insert from
    # the store command the domain supplies.
    {EzagentPluginForgejo.CredentialRecord, "forgejo_credentials"},
```

- [ ] **Step 3: Write the failing test**

Create `apps/ezagent_plugin_forgejo/test/ezagent_plugin_forgejo/credential_record_test.exs`:

```elixir
defmodule EzagentPluginForgejo.CredentialRecordTest do
  use ExUnit.Case, async: false

  alias EzagentCore.Repo
  alias EzagentPluginForgejo.CredentialRecord

  @ws "workspace://acme"
  @credential Jason.encode!(%{"access_token" => "at-1", "refresh_token" => "rt-1"})

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  test "a stored credential reads back exactly" do
    assert {:ok, %{credential_ref: ref, credential_version: 1}} =
             CredentialRecord.insert(@ws, @credential)

    assert {:ok, @credential} = CredentialRecord.fetch_credential(ref)
  end

  test "two inserts yield distinct refs" do
    {:ok, %{credential_ref: a}} = CredentialRecord.insert(@ws, @credential)
    {:ok, %{credential_ref: b}} = CredentialRecord.insert(@ws, @credential)
    refute a == b
  end

  # The whole reason this table exists. If it regresses, a credential sits in
  # plaintext in Postgres.
  test "the credential is not readable from the stored row" do
    {:ok, %{credential_ref: ref}} = CredentialRecord.insert(@ws, @credential)

    row = Repo.get!(CredentialRecord, ref)
    stored = :erlang.term_to_binary({row.ciphertext, row.nonce, row.key_id})

    refute stored =~ "at-1"
    refute stored =~ "rt-1"
  end

  test "the row records the sealing key so rotation can open it later" do
    {:ok, %{credential_ref: ref}} = CredentialRecord.insert(@ws, @credential)

    row = Repo.get!(CredentialRecord, ref)
    assert is_binary(row.key_id) and row.key_id != ""
    assert is_binary(row.key_fingerprint)
  end

  test "replace with the expected version bumps it and rewrites the credential" do
    {:ok, %{credential_ref: ref}} = CredentialRecord.insert(@ws, @credential)
    rotated = Jason.encode!(%{"access_token" => "at-2", "refresh_token" => "rt-2"})

    assert {:ok, %{credential_ref: ^ref, credential_version: 2}} =
             CredentialRecord.replace(ref, rotated, 1)

    assert {:ok, ^rotated} = CredentialRecord.fetch_credential(ref)
  end

  test "replace with a stale version is refused and leaves the credential intact" do
    {:ok, %{credential_ref: ref}} = CredentialRecord.insert(@ws, @credential)

    assert {:error, :stale_version} = CredentialRecord.replace(ref, "should-not-land", 7)
    assert {:ok, @credential} = CredentialRecord.fetch_credential(ref)
  end

  test "replacing an unknown ref is a conflict" do
    assert {:error, :credential_conflict} = CredentialRecord.replace("nope", "x", 1)
  end

  test "version reports the current version, and conflicts for an unknown ref" do
    {:ok, %{credential_ref: ref}} = CredentialRecord.insert(@ws, @credential)

    assert {:ok, 1} = CredentialRecord.version(ref)
    assert {:error, :credential_conflict} = CredentialRecord.version("nope")
  end

  test "a deleted credential can no longer be fetched" do
    {:ok, %{credential_ref: ref}} = CredentialRecord.insert(@ws, @credential)

    assert :ok = CredentialRecord.delete(ref)
    assert {:error, :credential_conflict} = CredentialRecord.fetch_credential(ref)
  end

  test "deleting twice stays ok" do
    {:ok, %{credential_ref: ref}} = CredentialRecord.insert(@ws, @credential)
    assert :ok = CredentialRecord.delete(ref)
    assert :ok = CredentialRecord.delete(ref)
  end
end
```

- [ ] **Step 4: Run it to verify it fails**

```bash
MIX_ENV=test POSTGRES_PORT=15432 mix ecto.migrate
MIX_ENV=test POSTGRES_PORT=15432 mix test \
  apps/ezagent_plugin_forgejo/test/ezagent_plugin_forgejo/credential_record_test.exs
```

Expected: FAIL with `EzagentPluginForgejo.CredentialRecord is not available`.

- [ ] **Step 5: Write the module**

Create `apps/ezagent_plugin_forgejo/lib/ezagent_plugin_forgejo/credential_record.ex`:

```elixir
defmodule EzagentPluginForgejo.CredentialRecord do
  @moduledoc """
  Durable, sealed custody for one Forgejo OAuth credential.

  Sealed by `Ezagent.ProviderConnection.SealedEnvelope` — the same keyed,
  rotatable envelope the provider-connection domain uses for its own
  authorization records, rather than a third private AES implementation. The
  credential_ref is bound into the AAD, so a ciphertext cannot be moved to
  another row.

  ## Why durable at all

  This replaced an ETS table owned by one Agent. That table dies with its owner,
  so one crash wiped every user's credential on the node — including the refresh
  token, which made recovery a browser re-authorization per user per instance
  rather than a renewal. `provider_connections` meanwhile kept pointing at the
  vanished rows, so connections looked active and failed on lease.
  """

  use Ecto.Schema

  import Ecto.Query, only: [from: 2]

  alias Ezagent.ProviderConnection.SealedEnvelope
  alias EzagentCore.Repo

  @purpose :provider_credential

  @primary_key false
  schema "forgejo_credentials" do
    field(:credential_ref, :string, primary_key: true)
    field(:workspace_uri, :string)
    field(:credential_version, :integer)
    field(:key_id, :string)
    field(:key_fingerprint, :binary)
    field(:nonce, :binary)
    field(:ciphertext, :binary)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Seals and stores a credential, returning the ref the domain will carry."
  @spec insert(String.t(), String.t()) ::
          {:ok, %{credential_ref: String.t(), credential_version: pos_integer()}}
          | {:error, atom()}
  def insert(workspace_uri, credential)
      when is_binary(workspace_uri) and is_binary(credential) do
    ref = "forgejo-credential-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))

    with {:ok, snapshot} <- SealedEnvelope.snapshot() do
      envelope = SealedEnvelope.seal(snapshot, :active, @purpose, credential, aad(ref))
      now = DateTime.utc_now()

      Repo.insert!(%__MODULE__{
        credential_ref: ref,
        workspace_uri: workspace_uri,
        credential_version: 1,
        key_id: envelope.key_id,
        key_fingerprint: envelope.key_fingerprint,
        nonce: envelope.nonce,
        ciphertext: envelope.ciphertext,
        inserted_at: now,
        updated_at: now
      })

      {:ok, %{credential_ref: ref, credential_version: 1}}
    end
  end

  @doc "Opens the stored credential."
  @spec fetch_credential(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def fetch_credential(credential_ref) when is_binary(credential_ref) do
    with {:ok, snapshot} <- SealedEnvelope.snapshot(),
         %__MODULE__{} = row <- Repo.get(__MODULE__, credential_ref) do
      SealedEnvelope.open(snapshot, @purpose, envelope_of(row), aad(credential_ref))
    else
      nil -> {:error, :credential_conflict}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns the stored version, for the domain's expected-version checks."
  @spec version(String.t()) :: {:ok, pos_integer()} | {:error, :credential_conflict}
  def version(credential_ref) when is_binary(credential_ref) do
    case Repo.one(
           from(r in __MODULE__,
             where: r.credential_ref == ^credential_ref,
             select: r.credential_version
           )
         ) do
      nil -> {:error, :credential_conflict}
      version -> {:ok, version}
    end
  end

  @doc """
  Re-seals a credential under a version CAS.

  The update is guarded by `credential_version` in the WHERE clause, so two
  concurrent replacements cannot both win: the loser sees zero rows updated and
  gets `:stale_version` rather than silently overwriting.
  """
  @spec replace(String.t(), String.t(), pos_integer()) ::
          {:ok, %{credential_ref: String.t(), credential_version: pos_integer()}}
          | {:error, atom()}
  def replace(credential_ref, credential, expected_version)
      when is_binary(credential_ref) and is_binary(credential) and is_integer(expected_version) do
    with {:ok, snapshot} <- SealedEnvelope.snapshot() do
      envelope = SealedEnvelope.seal(snapshot, :active, @purpose, credential, aad(credential_ref))
      next = expected_version + 1

      {count, _returned} =
        Repo.update_all(
          from(r in __MODULE__,
            where:
              r.credential_ref == ^credential_ref and
                r.credential_version == ^expected_version
          ),
          set: [
            credential_version: next,
            key_id: envelope.key_id,
            key_fingerprint: envelope.key_fingerprint,
            nonce: envelope.nonce,
            ciphertext: envelope.ciphertext,
            updated_at: DateTime.utc_now()
          ]
        )

      case count do
        1 -> {:ok, %{credential_ref: credential_ref, credential_version: next}}
        0 -> miss_reason(credential_ref)
      end
    end
  end

  @doc "Removes a credential. Deleting an absent one is already the desired state."
  @spec delete(String.t()) :: :ok
  def delete(credential_ref) when is_binary(credential_ref) do
    Repo.delete_all(from(r in __MODULE__, where: r.credential_ref == ^credential_ref))
    :ok
  end

  # Zero rows updated means either the ref is gone or the version moved. The
  # domain treats those differently, so they must not collapse into one code.
  defp miss_reason(credential_ref) do
    case version(credential_ref) do
      {:ok, _other} -> {:error, :stale_version}
      {:error, reason} -> {:error, reason}
    end
  end

  defp envelope_of(%__MODULE__{
         key_id: key_id,
         key_fingerprint: fingerprint,
         nonce: nonce,
         ciphertext: ciphertext
       }),
       do: %{
         key_id: key_id,
         key_fingerprint: fingerprint,
         nonce: nonce,
         ciphertext: ciphertext
       }

  # The ref is bound into the additional data, so a ciphertext copied to another
  # row will not open.
  defp aad(credential_ref), do: %{credential_ref: credential_ref}
end
```

- [ ] **Step 6: Run the test to verify it passes**

```bash
MIX_ENV=test POSTGRES_PORT=15432 mix test \
  apps/ezagent_plugin_forgejo/test/ezagent_plugin_forgejo/credential_record_test.exs
```

Expected: `10 tests, 0 failures`.

- [ ] **Step 7: Run the gate**

```bash
MIX_ENV=test POSTGRES_PORT=15432 mix ci.fast
```

Expected: EXIT=0. If `PerTenantTablesHaveWorkspaceColumnTest` still names `forgejo_credentials`, Step 2 was missed.

- [ ] **Step 8: Commit**

```bash
mix format apps/ezagent_plugin_forgejo/lib/ezagent_plugin_forgejo/credential_record.ex \
  apps/ezagent_plugin_forgejo/test/ezagent_plugin_forgejo/credential_record_test.exs \
  apps/ezagent_core/priv/repo_pg/migrations/20260730120000_create_forgejo_credentials.exs \
  apps/ezagent_core/test/invariants/per_tenant_tables_have_workspace_column_test.exs
git add apps/ezagent_plugin_forgejo/lib/ezagent_plugin_forgejo/credential_record.ex \
  apps/ezagent_plugin_forgejo/test/ezagent_plugin_forgejo/credential_record_test.exs \
  apps/ezagent_core/priv/repo_pg/migrations/20260730120000_create_forgejo_credentials.exs \
  apps/ezagent_core/test/invariants/per_tenant_tables_have_workspace_column_test.exs
git commit -m "feat(forgejo): durable sealed credential record

Per-tenant table sealed by the domain's SealedEnvelope, not a private AES
implementation. Version CAS in the WHERE clause so a losing concurrent
replacement gets :stale_version instead of overwriting. The credential_ref is
bound into the AAD, so a ciphertext cannot be moved between rows.

Not yet wired: ForgejoCredentialBackend still uses ETS. Next task switches it.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: Switch the backend to the durable record; delete `Sealed`

**Files:**
- Modify: `apps/ezagent_plugin_forgejo/lib/ezagent_plugin_forgejo/forgejo_credential_backend.ex`
- Modify: `apps/ezagent_plugin_forgejo/lib/ezagent_plugin_forgejo/oauth_app.ex`
- Delete: `apps/ezagent_plugin_forgejo/lib/ezagent_plugin_forgejo/sealed.ex`
- Modify: `config/config.exs`
- Modify: `apps/ezagent_plugin_forgejo/test/ezagent_plugin_forgejo/forgejo_credential_backend_test.exs`
- Modify: `apps/ezagent_plugin_forgejo/test/ezagent_plugin_forgejo/credential_refresh_test.exs`
- Modify: `apps/ezagent_plugin_forgejo/test/ezagent_plugin_forgejo/oauth_app_test.exs`
- Modify: `apps/ezagent_plugin_forgejo/test/e2e/forgejo_local_e2e_test.exs`, `.../credential_source_test.exs`, `.../forgejo_adapter_read_test.exs`, `.../forgejo_adapter_write_test.exs`, `.../forgejo_live_test.exs`

**Interfaces:**
- Consumes: `CredentialRecord.insert/2`, `fetch_credential/1`, `version/1`, `replace/3`, `delete/1` (Task 4).
- Produces: the `CredentialBackend` callbacks keep their existing shapes. **One changes:** `store/1` now requires `workspace_uri`.

**`store/1` must start requiring `workspace_uri`.** The real caller already sends it — `Support.credential_command/3` includes `workspace_uri: operation.workspace_uri`. The current clause matches only `credential_material`, and every existing test calls it with only that key, so the tests describe a command shape no caller sends. The new table needs the workspace, so this is the moment to match reality.

- [ ] **Step 1: Update the tests to the real command shape and the new storage**

In each of the seven test files listed above, every `ForgejoCredentialBackend.store(%{credential_material: ...})` becomes:

```elixir
ForgejoCredentialBackend.store(%{
  workspace_uri: "workspace://acme",
  credential_material: {:write_only_handoff, credential}
})
```

Two tests reach into ETS directly and must move to the table. In `forgejo_credential_backend_test.exs`:

```elixir
    test "the token is not recoverable from the stored row" do
      ref = store!()

      row = EzagentCore.Repo.get!(EzagentPluginForgejo.CredentialRecord, ref)
      stored = :erlang.term_to_binary({row.ciphertext, row.nonce})

      refute stored =~ @pat
    end
```

In `forgejo_adapter_read_test.exs` and `forgejo_local_e2e_test.exs`, replace
`:ets.delete_all_objects(:forgejo_credential_tokens)` with:

```elixir
      EzagentCore.Repo.delete_all(EzagentPluginForgejo.CredentialRecord)
```

Every test that touches the table needs `:ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)` in `setup` — `forgejo_credential_backend_test.exs` and `credential_refresh_test.exs` do not have it yet. Add it.

- [ ] **Step 2: Run them to verify they fail**

```bash
MIX_ENV=test POSTGRES_PORT=15432 mix test apps/ezagent_plugin_forgejo/test
```

Expected: failures in the credential-backend and refresh suites — `store/1` has no clause matching the new command, and `CredentialRecord` is not consulted.

- [ ] **Step 3: Rewrite the backend's storage**

In `forgejo_credential_backend.ex`: delete `start_link/1`, `child_spec/1`, `@table_name`, `@handoff_table` and the `Sealed` alias; the process existed only to own the ETS tables. Remove it from `children/0` in `application.ex`.

The handoff vault stays in ETS **deliberately** — it is a within-operation artifact, and losing it fails a refresh that the domain retries, unlike losing the credential. Keep one Agent for it only.

```elixir
  @impl true
  def store(%{workspace_uri: workspace_uri, credential_material: {:write_only_handoff, token}}),
    do: CredentialRecord.insert(workspace_uri, token)

  @impl true
  def replace(%{
        credential_material: {:write_only_handoff, handoff_ref},
        expected_credential_version: expected_version
      })
      when is_binary(handoff_ref) do
    case :ets.take(@handoff_table, handoff_ref) do
      [{^handoff_ref, credential, target_ref}] ->
        CredentialRecord.replace(target_ref, credential, expected_version)

      [] ->
        {:error, :credential_conflict}
    end
  end

  @impl true
  def replace(%{
        credential_material: {:write_only_handoff, new_token},
        prior_credential_ref: prior_ref,
        expected_credential_version: expected_version
      })
      when is_binary(prior_ref) do
    CredentialRecord.replace(prior_ref, new_token, expected_version)
  end

  def replace(_command), do: {:error, :credential_conflict}

  @impl true
  def status(%{credential_ref: ref}) do
    case CredentialRecord.version(ref) do
      {:ok, version} -> {:ok, %{credential_ref: ref, credential_version: version}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def lease_for_operation(%{credential_ref: ref}) do
    case CredentialRecord.fetch_credential(ref) do
      {:ok, credential} ->
        {:ok, %{credential: credential, credential_ref: ref, expires_at: nil}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def revoke(%{credential_ref: ref}), do: CredentialRecord.delete(ref)
```

`begin_refresh_exchange/1` now reads the credential through `CredentialRecord.fetch_credential/1` and carries the **plaintext-free** handle it already carried; keep `%{ref: ref}` in `private` and fetch inside `consume_refresh_exchange/1` so an un-consumed exchange leaves no decrypted token in a struct:

```elixir
  @impl true
  def begin_refresh_exchange(%{
        current_credential_ref: ref,
        scope_authority: authority,
        scope_token: token,
        scope_binding_digest: digest
      }) do
    case CredentialRecord.version(ref) do
      {:ok, _version} ->
        {:ok, RefreshUse.new(authority, token, digest, __MODULE__, %{ref: ref})}

      {:error, reason} ->
        {:error, reason}
    end
  end
```

and in `consume_refresh_exchange/1` replace the `Sealed.open(sealed)` step with:

```elixir
         %{ref: ref} <- RefreshUse.private(use),
         {:ok, credential} <- CredentialRecord.fetch_credential(ref),
```

`park_handoff/3` stores the replacement **unsealed** in the ETS vault (it never leaves the VM and is consumed within the operation), so drop the `Sealed.seal/1` call there:

```elixir
    :ets.insert(@handoff_table, {reference, material, target_ref})
```

- [ ] **Step 4: Switch `oauth_app.ex` to `SealedEnvelope` and add the key columns**

Add a migration `apps/ezagent_core/priv/repo_pg/migrations/20260730120100_add_envelope_key_to_forgejo_oauth_apps.exs`:

```elixir
defmodule EzagentCore.Repo.Migrations.AddEnvelopeKeyToForgejoOauthApps do
  use Ecto.Migration

  # `forgejo_oauth_apps` was sealed by a private AES implementation whose
  # envelope carried no key identity, so changing the configured key made every
  # stored client secret unopenable. Moving it onto
  # `Ezagent.ProviderConnection.SealedEnvelope` requires the key columns the
  # domain's own records already carry.
  #
  # No backfill: the table is empty in every deployment (the Forgejo line has
  # not shipped), so the columns are simply NOT NULL from the start. If a row
  # ever exists when this runs, the migration fails loudly rather than
  # inventing a key id for ciphertext nobody can attribute.
  def change do
    alter table(:forgejo_oauth_apps) do
      add :key_id, :string, null: false
      add :key_fingerprint, :binary, null: false
    end

    rename table(:forgejo_oauth_apps), :client_secret_ciphertext, to: :ciphertext
    rename table(:forgejo_oauth_apps), :client_secret_nonce, to: :nonce
  end
end
```

Then in `oauth_app.ex`: replace `alias EzagentPluginForgejo.{Instance, Sealed}` with `alias Ezagent.ProviderConnection.SealedEnvelope` plus `alias EzagentPluginForgejo.Instance`, rename the schema fields to `:key_id`, `:key_fingerprint`, `:nonce`, `:ciphertext`, and replace the seal/open calls:

```elixir
      {:ok, snapshot} = SealedEnvelope.snapshot()

      envelope =
        SealedEnvelope.seal(
          snapshot,
          :active,
          :provider_oauth_app,
          secret,
          %{workspace_uri: workspace_uri, governed_host: host}
        )
```

and on the read side:

```elixir
        with {:ok, snapshot} <- SealedEnvelope.snapshot(),
             {:ok, secret} <-
               SealedEnvelope.open(
                 snapshot,
                 :provider_oauth_app,
                 %{
                   key_id: key_id,
                   key_fingerprint: fingerprint,
                   nonce: nonce,
                   ciphertext: ciphertext
                 },
                 %{workspace_uri: workspace_uri, governed_host: host}
               ) do
```

- [ ] **Step 5: Delete `sealed.ex` and its config key**

```bash
git rm apps/ezagent_plugin_forgejo/lib/ezagent_plugin_forgejo/sealed.ex
```

In `config/config.exs`, delete the whole `config :ezagent_plugin_forgejo, token_encryption_key: ...` block and its comment. One keyring now.

- [ ] **Step 6: Run the plugin suite**

```bash
MIX_ENV=test POSTGRES_PORT=15432 mix ecto.migrate
MIX_ENV=test POSTGRES_PORT=15432 mix test apps/ezagent_plugin_forgejo/test
```

Expected: all green (the count will be near 198; 1 excluded for `:live_forgejo`).

- [ ] **Step 7: Prove durability — the point of the whole PR**

Add to `apps/ezagent_plugin_forgejo/test/ezagent_plugin_forgejo/credential_record_test.exs`:

```elixir
  # The defect this PR closes. The credential used to live in an ETS table owned
  # by one Agent, so killing that process wiped every user's credential on the
  # node. Restarting the owning process must now change nothing.
  test "a credential survives the backend process being killed" do
    {:ok, %{credential_ref: ref}} = CredentialRecord.insert(@ws, @credential)

    case Process.whereis(EzagentPluginForgejo.ForgejoCredentialBackend) do
      nil -> :ok
      pid -> Process.exit(pid, :kill)
    end

    assert {:ok, @credential} = CredentialRecord.fetch_credential(ref)
  end
```

```bash
MIX_ENV=test POSTGRES_PORT=15432 mix test \
  apps/ezagent_plugin_forgejo/test/ezagent_plugin_forgejo/credential_record_test.exs
```

Expected: `11 tests, 0 failures`.

- [ ] **Step 8: Mutation-verify the CAS and the AAD binding**

Prove the two guards are load-bearing rather than decorative.

```bash
S=/tmp/mutation && mkdir -p $S
F=apps/ezagent_plugin_forgejo/lib/ezagent_plugin_forgejo/credential_record.ex
cp $F $S/cr.bak

# Mutation 1: drop the version from the CAS
python3 - <<'PY'
p='apps/ezagent_plugin_forgejo/lib/ezagent_plugin_forgejo/credential_record.ex'
s=open(p).read()
old="""            where:
              r.credential_ref == ^credential_ref and
                r.credential_version == ^expected_version"""
new="""            where: r.credential_ref == ^credential_ref"""
assert s.count(old) == 1
open(p,'w').write(s.replace(old,new))
PY
MIX_ENV=test POSTGRES_PORT=15432 mix test apps/ezagent_plugin_forgejo/test/ezagent_plugin_forgejo/credential_record_test.exs 2>&1 | grep -E "tests?, [0-9]+ failure"
cp $S/cr.bak $F

# Mutation 2: drop the ref from the AAD
python3 - <<'PY'
p='apps/ezagent_plugin_forgejo/lib/ezagent_plugin_forgejo/credential_record.ex'
s=open(p).read()
old='  defp aad(credential_ref), do: %{credential_ref: credential_ref}'
new='  defp aad(_credential_ref), do: %{}'
assert s.count(old) == 1
open(p,'w').write(s.replace(old,new))
PY
MIX_ENV=test POSTGRES_PORT=15432 mix test apps/ezagent_plugin_forgejo/test/ezagent_plugin_forgejo/credential_record_test.exs 2>&1 | grep -E "tests?, [0-9]+ failure"
cp $S/cr.bak $F
```

Expected: mutation 1 turns the stale-version test red. **Mutation 2 is expected to stay GREEN** — no current test moves a ciphertext between rows. That is a real gap, so add the test that closes it:

```elixir
  # AAD binds a ciphertext to its row. Without this, a sealed credential copied
  # into another row would open there.
  test "a ciphertext moved to another row does not open" do
    {:ok, %{credential_ref: a}} = CredentialRecord.insert(@ws, @credential)
    {:ok, %{credential_ref: b}} = CredentialRecord.insert(@ws, "other-credential")

    row_a = Repo.get!(CredentialRecord, a)

    Repo.update_all(
      Ecto.Query.from(r in CredentialRecord, where: r.credential_ref == ^b),
      set: [
        key_id: row_a.key_id,
        key_fingerprint: row_a.key_fingerprint,
        nonce: row_a.nonce,
        ciphertext: row_a.ciphertext
      ]
    )

    assert {:error, :authentication_failed} = CredentialRecord.fetch_credential(b)
  end
```

Re-run mutation 2 and confirm it now turns red, then restore.

- [ ] **Step 9: Run the gate and the live E2E**

```bash
MIX_ENV=test POSTGRES_PORT=15432 mix ci.fast
```

Expected: EXIT=0.

```bash
set -a; . /home/huangjiajia/ezagent/forgejo-token.txt; set +a
FORGEJO_LIVE_TOKEN="$FORGEJO_TOKEN" FORGEJO_LIVE_REPO="$FORGEJO_REPO" \
FORGEJO_LIVE_HOST="code.hyprial.com" FORGEJO_LIVE_PROXY="http://127.0.0.1:7890" \
MIX_ENV=test POSTGRES_PORT=15432 \
mix test apps/ezagent_plugin_forgejo/test/e2e/forgejo_live_test.exs --include live_forgejo
```

Expected: `1 test, 0 failures`. This proves the durable path works against a real instance, not only against the stub.

- [ ] **Step 10: Update the design doc and commit**

In `docs/superpowers/specs/2026-07-29-forgejo-provider-v1-design.md`, replace §12.1 ("已知限制") with a note that the limitation is closed, naming the table and the shared envelope, and keep the GitHub asymmetry paragraph (GitHub is `provider_held` and still ETS, deliberately).

```bash
mix format $(git diff --name-only | grep -E '\.exs?$')
git add -A
git commit -m "feat(forgejo): credentials durable, sealed by the domain's envelope

Closes design §12.1. The credential moved from an ETS table owned by one Agent
into a per-tenant Postgres table sealed by SealedEnvelope — one crash of that
process used to wipe every user's Forgejo credential on the node, including the
refresh token, making recovery a browser re-authorization per user per instance.

store/1 now requires workspace_uri. The real caller (Support.credential_command/3)
always sent it; the old clause matched only credential_material, so every test
described a command shape no caller sends.

oauth_apps moved onto the same envelope and gained the key_id / key_fingerprint
it was missing — its old envelope had no key identity, so changing the configured
key made every stored client secret unopenable. Deleted Sealed and the
plugin-local token_encryption_key: one keyring now.

The handoff vault stays in ETS on purpose: it is a within-operation artifact, and
losing it fails a refresh the domain retries, unlike losing the credential.

Mutation-verified: dropping the version from the CAS turns the stale-version test
red; dropping the ref from the AAD stayed green until the moved-ciphertext test
was added, which is why that test exists.

Live E2E against code.hyprial.com: 1 test, 0 failures.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage.** The agreed scope was: (1) extract the domain's duplicated sealing into one shared module — Tasks 1–3; (2) make Forgejo credentials durable using `AuthorizationBackendRecord`'s column shape — Tasks 4–5; (3) do not build a generic cross-provider credential store, that belongs to the deferred Path B — respected, the table is plugin-owned; (4) do not rename `AuthorizationKeyRing` or its env var — respected, documented in Task 1's moduledoc; (5) put the module at domain top level, not under `LocalAuthorizationBackend.*` — respected. Two items surfaced during the precondition survey and are covered: the `store/1` command-shape mismatch (Task 5 Step 1) and the missing `key_id` on `forgejo_oauth_apps` (Task 5 Step 4).

**Not covered, deliberately.** GitHub's backend stays ETS: it is provider-held, so an ETS wipe costs identity linkage rather than capability. The `application_test.exs` flakiness is #189's line, not this plan's. The four other AES sites in the repo (`agent_bridge/token_store.ex`, `github_token_store.ex`, and the domain's two — now one) are not consolidated here; that convergence is Path B's scope and would also have to cover the cap signing key, which is stored plaintext today.

**Placeholder scan.** No TBDs. Every code step carries the code; every command carries its expected output. Task 2's call sites are given as a name-to-name table rather than pasted bodies because the argument lists must not change — the instruction is mechanical substitution, and pasting eleven near-identical call sites would invite editing them.

**Type consistency.** `SealedEnvelope.snapshot/0` returns `{:ok, %{active_key_id:, keys:}}` in Task 1 and is consumed with that shape in Tasks 2, 3, 4 and 5. `seal/5` takes `:active | binary` in second position everywhere. `open/4` is `(snapshot, purpose, envelope, aad)` at every call site. `CredentialRecord`'s five functions are declared in Task 4's Interfaces block with the exact names and arities Task 5 calls. `store/1`'s new required key is `workspace_uri`, matching `Support.credential_command/3`.

**Known-risk register.** Task 3's allowlist is the one place a mechanical extraction could silently widen a security boundary; it has both a written warning and a test. Task 5 Step 8's mutation 2 is expected to pass at first — that is the point, it exposes a missing test rather than confirming a present one.
