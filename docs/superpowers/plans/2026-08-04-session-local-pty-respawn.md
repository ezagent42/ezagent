# Session-local PTY Respawn Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep an interactively authenticated, session-local Codex agent usable when a completion request heals or starts its subprocess bridge.

**Architecture:** Extend the existing plain-data cascade respawn snapshot with the credential-required boolean, and restore both that boolean and the already-persisted source policy into `Ezagent.Credential.Resolver`. The change stays at the TemplateSpawn/CascadeRuntime boundary; no credentials, PTY state, or authorization rules are persisted.

**Tech Stack:** Elixir 1.19, OTP 28, ExUnit, Ecto-backed `EzagentCore.DataCase`.

## Global Constraints

- Missing or malformed `credential_required?` values remain fail-closed as `true`.
- Only literal booleans are serialized; no runtime functions or credential material enter respawn data.
- Session-local agents must not consult or adopt reusable user/workspace credential sources during rehydration.
- Required-credential and sourced cascades retain their current behavior.
- Use `mix precommit` after all focused tests pass.
- Preserve the unrelated modified files `.superpowers/sdd/task-1-report.md` and `.superpowers/sdd/task-2-report.md`.

---

## File structure

- Modify `apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn/cascade.ex`: serialize the boolean credential requirement in the durable cascade-resolution snapshot.
- Modify `apps/ezagent_core/lib/ezagent/credential/cascade_runtime.ex`: restore the persisted source policy into resolver inputs.
- Modify `apps/ezagent_domain_session/test/ezagent/entity/agent_cascade_activation_test.exs`: exercise snapshot serialization and runtime rehydration through public APIs.

### Task 1: Preserve and restore session-local credential semantics

**Files:**
- Modify: `apps/ezagent_domain_session/test/ezagent/entity/agent_cascade_activation_test.exs`
- Modify: `apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn/cascade.ex`
- Modify: `apps/ezagent_core/lib/ezagent/credential/cascade_runtime.ex`

**Interfaces:**
- Consumes: `Ezagent.Entity.Agent.sanitize_respawn_template_data(map(), map()) :: map()` and `Ezagent.Credential.CascadeRuntime.rehydrate_respawn_data(URI.t(), map()) :: {:ok, map()} | {:error, term()}`.
- Produces: a string-keyed respawn field `"credential_required"` is deliberately not introduced; the exact persisted field is `"credential_required?" => boolean()`. Runtime resolver inputs gain `credential_source_policy: :session_local | String.t() | nil` from that snapshot.

- [ ] **Step 1: Write the failing snapshot test**

Extend the existing test named `respawn_template_data keeps cascade resolution inputs, not runtime cascade functions` so its template resolution contains the optional flag:

```elixir
cascade_resolution: %{
  owner_uri: @owner_uri,
  workspace_uri: @workspace_uri,
  credential_source_uri: URI.new!("entity://team-alpha/agent/alice-source"),
  credential_source_policy: :session_local,
  credential_required?: false,
  layer_dir_for: fn _ -> :skip end,
  source_dir_for: fn _ -> {:ok, "/tmp/source"} end
}
```

Require the snapshot to retain both plain-data fields:

```elixir
assert sanitized["cascade_resolution"] == %{
         "owner_uri" => URI.to_string(@owner_uri),
         "workspace_uri" => URI.to_string(@workspace_uri),
         "credential_source_uri" => "entity://team-alpha/agent/alice-source",
         "credential_source_policy" => "session_local",
         "credential_required?" => false
       }
```

- [ ] **Step 2: Run the snapshot test and verify RED**

Run:

```bash
mise exec -- mix test apps/ezagent_domain_session/test/ezagent/entity/agent_cascade_activation_test.exs:135
```

Expected: FAIL because `sanitized["cascade_resolution"]` does not contain `"credential_required?"`.

- [ ] **Step 3: Write the failing runtime-policy test**

Add a focused test after the existing rehydration test. It intentionally leaves the credential required so only restoration of `session_local` can make it keyless:

```elixir
test "rehydrate_respawn_data restores session-local credential policy" do
  agent_uri = Ezagent.URI.agent("team-alpha", "session-local-restart-#{uniq()}")

  respawn_data = %{
    "flavor" => "codex",
    "cascade_resolution" => %{
      "owner_uri" => URI.to_string(@owner_uri),
      "workspace_uri" => URI.to_string(@workspace_uri),
      "credential_source_policy" => "session_local",
      "credential_required?" => true
    }
  }

  assert {:ok, rehydrated} =
           Ezagent.Credential.CascadeRuntime.rehydrate_respawn_data(agent_uri, respawn_data)

  assert %{layer_dirs: [], source_dir_for: source_dir_for} = rehydrated["cascade"]
  assert is_function(source_dir_for, 1)
end
```

- [ ] **Step 4: Run the runtime-policy test and verify RED**

Run the test file:

```bash
mise exec -- mix test apps/ezagent_domain_session/test/ezagent/entity/agent_cascade_activation_test.exs
```

Expected: FAIL with `{:error, :no_credential_source}` because `CascadeRuntime` currently drops `credential_source_policy`.

- [ ] **Step 5: Implement boolean snapshot serialization**

In `cascade_resolution_snapshot/1`, add `:credential_required?` to the allowed-key list and add a boolean serialization arm before the generic string arm:

```elixir
[
  :owner_uri,
  :workspace_uri,
  :session_uri,
  :explicit_source,
  :credential_source_uri,
  :credential_source_policy,
  :credential_required?,
  :workspace_layer_uri,
  :user_layer_uri,
  :session_layer_uri
]
|> Enum.reduce(%{}, fn key, acc ->
  case Map.get(resolution, key) || Map.get(resolution, Atom.to_string(key)) do
    %URI{} = uri ->
      Map.put(acc, Atom.to_string(key), uri_to_respawn_value(uri))

    value when key == :credential_required? and is_boolean(value) ->
      Map.put(acc, Atom.to_string(key), value)

    value when is_binary(value) and value != "" ->
      Map.put(acc, Atom.to_string(key), value)

    value when key == :credential_source_policy and value == :session_local ->
      Map.put(acc, Atom.to_string(key), Atom.to_string(value))

    _ ->
      acc
  end
end)
```

Do not use `||` to read the boolean because it discards `false`. Replace the case input with a helper or `Map.fetch/2`-based lookup that preserves false, for example:

```elixir
defp resolution_value(resolution, key) do
  case Map.fetch(resolution, key) do
    {:ok, value} -> value
    :error -> Map.get(resolution, Atom.to_string(key))
  end
end
```

and call `case resolution_value(resolution, key) do`.

- [ ] **Step 6: Restore source policy in CascadeRuntime**

Add the source policy to the resolver input map in `resolver_inputs/3`:

```elixir
credential_source_policy: field(resolution, :credential_source_policy),
credential_required?: field(resolution, :credential_required?) != false
```

`Resolver.pick_credential_source/1` already accepts atom or string `session_local`, so no new conversion or dependency is needed.

- [ ] **Step 7: Verify GREEN with the focused file**

Run:

```bash
mise exec -- mix test apps/ezagent_domain_session/test/ezagent/entity/agent_cascade_activation_test.exs
```

Expected: all tests pass, including the two new regression assertions.

- [ ] **Step 8: Add malformed-value fail-closed coverage**

Add a test showing that non-boolean values are omitted from respawn data:

```elixir
test "respawn_template_data omits malformed credential-required values" do
  sanitized =
    Agent.sanitize_respawn_template_data(%{}, %{
      cascade_resolution: %{
        owner_uri: @owner_uri,
        credential_required?: "false"
      }
    })

  refute Map.has_key?(sanitized["cascade_resolution"], "credential_required?")
end
```

- [ ] **Step 9: Run focused regression suites**

Run:

```bash
mise exec -- mix test apps/ezagent_domain_session/test/ezagent/entity/agent_cascade_activation_test.exs
mise exec -- mix test apps/ezagent_domain_agent/test/ezagent/entity/agent/template_spawn/cascade_credential_optional_test.exs
mise exec -- mix test apps/ezagent_core/test/ezagent/credential/resolver_test.exs
```

Expected: all three commands exit 0.

- [ ] **Step 10: Commit the repair**

```bash
git add apps/ezagent_domain_session/test/ezagent/entity/agent_cascade_activation_test.exs \
  apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn/cascade.ex \
  apps/ezagent_core/lib/ezagent/credential/cascade_runtime.ex
git commit -m "fix(agent): preserve session-local credentials on respawn"
```

### Task 2: Verify the integrated runtime

**Files:**
- No source files modified.

**Interfaces:**
- Consumes: the repaired respawn snapshot and current database at `127.0.0.1:55432`.
- Produces: a healthy development service at `http://world.localhost:10042/` with fresh capability caches and live Kinds.

- [ ] **Step 1: Run the project gate**

Run:

```bash
mise exec -- mix precommit
```

Expected: exit 0. If the repository has unrelated baseline failures, record the exact failing command and prove the focused suites from Task 1 still pass.

- [ ] **Step 2: Restart the port-10042 service**

Stop only the BEAM process currently listening for this worktree, then start from the worktree with:

```bash
PORT=10042 \
EZAGENT_PROVIDER_AUTH_ACTIVE_KEY_ID=local-dev-v1 \
EZAGENT_PROVIDER_AUTH_KEYS_JSON='{"local-dev-v1":"WlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlo="}' \
mise exec -- iex -S mix phx.server
```

Expected: Phoenix and Vite start without a bind error.

- [ ] **Step 3: Verify HTTP health**

Run:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' http://world.localhost:10042/
```

Expected: `200`.

- [ ] **Step 4: Verify admin capability and Page authorization in the fresh runtime**

Evaluate in the server IEx:

```elixir
admin = Ezagent.Entity.User.admin_uri()
session = Ezagent.URI.new!("session://system/hello-codex/hello-codex-2")

%{
  cap_count: MapSet.size(Ezagent.Identity.list_caps_for(admin)),
  page_authorized?:
    Ezagent.UI.SessionView.authorize_view(EzagentPluginHello.PageView, admin, session)
}
```

Expected: `cap_count` is greater than zero and `page_authorized?` is `true`.

- [ ] **Step 5: Verify the affected agent can rehydrate without a reusable source**

Read the `llm` member's respawn data from its live sandbox, confirm its cascade
resolution contains `"credential_source_policy" => "session_local"`, then call
the public `Ezagent.Credential.CascadeRuntime.rehydrate_respawn_data/2` with that
data. The existing `hello-codex-2` snapshot predates this repair and may omit
`"credential_required?"`; restoring the session-local policy is intentionally
sufficient for that legacy snapshot. Newly sanitized snapshots must contain
`"credential_required?" => false` as proven by Task 1.

Expected: `{:ok, rehydrated}` with a rebuilt `"cascade"`, never `{:error, :no_credential_source}`.

- [ ] **Step 6: Browser acceptance**

Open `http://world.localhost:10042/`, enter `hello-codex-2`, and verify:

1. Page preview is present.
2. Connect Codex does not return to login after the authenticated admission is settled.
3. Sending a new Hello UI request does not append `[agent error] generation_failed`.

If an external Codex provider call itself fails, inspect the structured error and distinguish provider/network failure from the repaired `:no_credential_source` path.
