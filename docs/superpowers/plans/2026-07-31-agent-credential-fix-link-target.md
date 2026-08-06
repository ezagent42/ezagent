# Agent Credential Fix Link Target Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a Hello credential-error card navigate to the API Keys page of the actual agent occupying the session's `llm` role, never to the `front-desk` sender or an agent-less route.

**Architecture:** Keep the error signal wire format unchanged. Add declarative `fix_role` metadata to the credential error code, resolve that role from the session's authorized member map while shaping message rows, and let the shared error renderer build the agent-specific URL from the resolved canonical URI.

**Tech Stack:** Elixir 1.19, Phoenix LiveView 1.1, ExUnit, World React renderer contract.

## Global Constraints

- The repair target for `agent_credential_missing` is the current session member whose `role_name` is exactly `"llm"`.
- The message sender is not the repair target; a `front-desk` error message must still link to `llm`.
- The generated route is `/identities/agents/<URI.encode_www_form(actual-agent-uri)>/api-keys`.
- If no unique `llm` member is resolvable, emit no direct repair link.
- Do not change the agent error-signal wire format.
- Do not run `mix precommit`; run only targeted tests.
- Preserve all unrelated dirty-worktree changes.

## File Structure

- Modify `apps/ezagent_plugin_world/lib/ezagent/world/error_code.ex`: declare the optional repair role on the credential error.
- Modify `apps/ezagent_plugin_world/lib/ezagent/world/error_renderer.ex`: consume a resolved repair agent URI and generate only an agent-specific API Keys route.
- Modify `apps/ezagent_plugin_world/lib/ezagent/world/error_cards.ex`: resolve a declared role against authorized session members and add it to the render context.
- Modify `apps/ezagent_plugin_world/lib/ezagent/world/conversation_data.ex`: provide the authorized member map to initial-history and pagination error-card rendering.
- Modify `apps/ezagent_plugin_world/test/ezagent/world/error_renderer_test.exs`: cover exact URL generation and no-target behavior.
- Modify `apps/ezagent_plugin_world/test/ezagent/world/error_cards_test.exs`: prove a `front-desk` sender links to a distinct `llm` member.
- Modify `apps/ezagent_plugin_world/test/ezagent/world/conversation_data_visibility_test.exs`: rerun the existing initial-history and pagination authorization contract against the reordered member/message reads.

---

### Task 1: Make the Error Renderer Require an Actual Agent Target

**Files:**
- Modify: `apps/ezagent_plugin_world/test/ezagent/world/error_renderer_test.exs`
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/error_code.ex`
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/error_renderer.ex`

**Interfaces:**
- Consumes: `ErrorCode.lookup("agent_credential_missing")`.
- Produces: `ErrorRenderer.render(code, fix_target_uri: agent_uri, ...)` and `ErrorRenderer.fix_path_to_url(:agent_keys_page, agent_uri)`.

- [ ] **Step 1: Write the failing renderer tests**

Add canonical URIs and require the exact encoded route:

```elixir
@llm_uri Ezagent.URI.new!("entity://system/agent/llm-1")

test "agent credential card links to the actual repair agent" do
  card =
    ErrorRenderer.render(@credential_code,
      user_can_fix: true,
      fix_target_uri: @llm_uri
    )

  assert card.layer == 1

  assert card.fix_link ==
           "/identities/agents/#{URI.encode_www_form(URI.to_string(@llm_uri))}/api-keys"
end

test "an unresolved repair target does not emit a misleading direct link" do
  card = ErrorRenderer.render(@credential_code, user_can_fix: true)

  assert card.layer != 1
  assert card.fix_link == nil
end
```

Update the URL helper test to assert:

```elixir
assert ErrorRenderer.fix_path_to_url(:agent_keys_page, @llm_uri) ==
         "/identities/agents/#{URI.encode_www_form(URI.to_string(@llm_uri))}/api-keys"
```

- [ ] **Step 2: Run the renderer test and verify RED**

Run:

```bash
mix test apps/ezagent_plugin_world/test/ezagent/world/error_renderer_test.exs
```

Expected: FAIL because `fix_path_to_url/2` and target-aware rendering do not exist, and the current implementation emits `/identities/agents/api-keys`.

- [ ] **Step 3: Add repair-role metadata and minimal target-aware rendering**

Extend the error-code message type with:

```elixir
optional(:fix_role) => String.t()
```

Set the credential entry to:

```elixir
fix_path: :agent_keys_page,
fix_role: "llm",
fix_owner: :workspace_founder
```

In `ErrorRenderer.render/2`, compute the concrete link before selecting Layer 1:

```elixir
fix_link =
  fix_path_to_url(
    code.message.fix_path,
    Keyword.get(opts, :fix_target_uri)
  )
```

Select Layer 1 only when `user_can_fix` and `fix_link` is non-nil. Pass the computed link into `layer1_card/2`. Implement:

```elixir
def fix_path_to_url(:agent_keys_page, %URI{} = agent_uri) do
  encoded = agent_uri |> URI.to_string() |> URI.encode_www_form()
  "/identities/agents/#{encoded}/api-keys"
end

def fix_path_to_url(_fix_path, _target_uri), do: nil
```

When a user can fix but the target cannot be resolved, continue through the existing Layer 2/3 policy instead of emitting a dead link.

- [ ] **Step 4: Run the renderer test and verify GREEN**

Run:

```bash
mix test apps/ezagent_plugin_world/test/ezagent/world/error_renderer_test.exs
```

Expected: PASS.

- [ ] **Step 5: Commit the target-aware renderer**

```bash
git add \
  apps/ezagent_plugin_world/lib/ezagent/world/error_code.ex \
  apps/ezagent_plugin_world/lib/ezagent/world/error_renderer.ex \
  apps/ezagent_plugin_world/test/ezagent/world/error_renderer_test.exs
git diff --cached --check
git commit -m "fix(world): require agent target for credential links"
```

### Task 2: Resolve the `llm` Role Instead of Using the Error Sender

**Files:**
- Modify: `apps/ezagent_plugin_world/test/ezagent/world/error_cards_test.exs`
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/error_cards.ex`
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/conversation_data.ex`
- Test if threading needs direct coverage: `apps/ezagent_plugin_world/test/ezagent/world/conversation_data_visibility_test.exs`

**Interfaces:**
- Consumes: error-code `message.fix_role`, authorized `%{URI.t() => member_meta}` session members, and the existing `ErrorCards.enrich/3` pipeline.
- Produces: `ErrorCards.viewer_ctx/4` with a role-to-agent repair target and `ErrorCards.live_viewer_ctx/1` that lazily reads current authorized members.

- [ ] **Step 1: Write the failing front-desk-versus-LLM test**

Give the row a front-desk sender and the render context a distinct LLM role member:

```elixir
@front_desk_uri Ezagent.URI.new!("entity://system/agent/front-desk-1")
@llm_uri Ezagent.URI.new!("entity://system/agent/llm-1")

@row %{
  "id" => "msg-123",
  "sender" => URI.to_string(@front_desk_uri),
  "sender_kind" => "agent",
  "text" => "[agent error] no_api_key"
}

test "front-desk credential error links to the session llm member" do
  body = ErrorSignal.reply_body({:no_api_key, "deepseek"})

  viewer_ctx = %{
    user_can_fix: true,
    fix_owner_display_name: "allen",
    role_members: %{"llm" => @llm_uri}
  }

  row = ErrorCards.enrich(@row, body, viewer_ctx)

  assert row["error_card"].fix_link ==
           "/identities/agents/#{URI.encode_www_form(URI.to_string(@llm_uri))}/api-keys"

  refute row["error_card"].fix_link =~ URI.encode_www_form(URI.to_string(@front_desk_uri))
end
```

Add a missing-role case asserting there is no Layer 1 link.

- [ ] **Step 2: Run the error-card test and verify RED**

Run:

```bash
mix test apps/ezagent_plugin_world/test/ezagent/world/error_cards_test.exs
```

Expected: FAIL because `ErrorCards.enrich/3` does not resolve `fix_role` from `role_members` or pass `fix_target_uri`.

- [ ] **Step 3: Implement role resolution in the shared error-card context**

Build role members from both atom- and string-keyed member facets:

```elixir
def role_members(members) when is_map(members) do
  Enum.reduce(members, %{}, fn
    {%URI{} = uri, meta}, acc when is_map(meta) ->
      case Map.get(meta, :role_name) || Map.get(meta, "role_name") do
        role when is_binary(role) -> Map.put_new(acc, role, uri)
        _ -> acc
      end

    _, acc ->
      acc
  end)
end
```

Extend `viewer_ctx/3` to a defaulted fourth argument:

```elixir
def viewer_ctx(caller_uri, caller_caps, workspace_uri, members \\ %{})
```

Store `role_members: role_members(members)`. In `enrich/3`, resolve:

```elixir
fix_target_uri =
  code && code.message[:fix_role] &&
    get_in(ctx, [:role_members, code.message.fix_role])
```

Pass `fix_target_uri` to `ErrorRenderer.render/2`. Never consult `row["sender"]` for the repair target.

- [ ] **Step 4: Thread authorized members through initial history and lazy live paths**

In `ConversationData.state_for/2`, obtain `SessionReads.members/2` before shaping messages, then construct the lazy viewer context with those same authorized members:

```elixir
with {:ok, members_map} <- SessionReads.members(caller_uri, session_uri),
     viewer_ctx =
       fn ->
         ErrorCards.viewer_ctx(caller_uri, caller_caps, workspace_uri, members_map)
       end,
     {:ok, message_rows} <- authorized_messages(session_uri, caller_uri, viewer_ctx) do
  ...
end
```

For `ErrorCards.live_viewer_ctx/1`, lazily resolve the current session's members through `SessionReads.members/2`; use `%{}` on authorization/read failure. This covers newly received messages and pagination without bypassing the session read chokepoint.

Use this failure-closed shape inside the returned zero-arity function:

```elixir
members =
  case {Map.get(assigns, :current_entity_uri), Map.get(assigns, :current_session_uri)} do
    {%URI{} = caller, %URI{} = session_uri} ->
      case SessionReads.members(caller, session_uri) do
        {:ok, members} -> members
        {:error, _reason} -> %{}
      end

    _ ->
      %{}
  end

viewer_ctx(
  Map.get(assigns, :current_entity_uri),
  Ezagent.World.PresenterCaps.load(assigns),
  Map.get(assigns, :current_workspace_uri),
  members
)
```

- [ ] **Step 5: Run targeted backend tests and verify GREEN**

Run:

```bash
mix test \
  apps/ezagent_plugin_world/test/ezagent/world/error_renderer_test.exs \
  apps/ezagent_plugin_world/test/ezagent/world/error_cards_test.exs \
  apps/ezagent_plugin_world/test/ezagent/world/conversation_data_visibility_test.exs
```

Expected: all tests PASS.

- [ ] **Step 6: Format only touched Elixir files and rerun targeted tests**

Run:

```bash
mix format \
  apps/ezagent_plugin_world/lib/ezagent/world/error_code.ex \
  apps/ezagent_plugin_world/lib/ezagent/world/error_renderer.ex \
  apps/ezagent_plugin_world/lib/ezagent/world/error_cards.ex \
  apps/ezagent_plugin_world/lib/ezagent/world/conversation_data.ex \
  apps/ezagent_plugin_world/test/ezagent/world/error_renderer_test.exs \
  apps/ezagent_plugin_world/test/ezagent/world/error_cards_test.exs \
  apps/ezagent_plugin_world/test/ezagent/world/conversation_data_visibility_test.exs

mix test \
  apps/ezagent_plugin_world/test/ezagent/world/error_renderer_test.exs \
  apps/ezagent_plugin_world/test/ezagent/world/error_cards_test.exs \
  apps/ezagent_plugin_world/test/ezagent/world/conversation_data_visibility_test.exs
```

Expected: formatter succeeds and all targeted tests PASS.

- [ ] **Step 7: Commit role-based target resolution**

```bash
git add \
  apps/ezagent_plugin_world/lib/ezagent/world/error_cards.ex \
  apps/ezagent_plugin_world/lib/ezagent/world/conversation_data.ex \
  apps/ezagent_plugin_world/test/ezagent/world/error_cards_test.exs \
  apps/ezagent_plugin_world/test/ezagent/world/conversation_data_visibility_test.exs
git diff --cached --check
git commit -m "fix(world): route credential repair to llm member"
```

- [ ] **Step 8: Verify the exact live route after recompilation**

Restart the local service only if Phoenix does not hot-reload the backend modules. Re-open the Hello credential error card and verify “前往修复” navigates to:

```text
http://world.localhost:10042/identities/agents/entity%3A%2F%2Fsystem%2Fagent%2F17ef3de3-768e-4a1d-819f-3d836f070ab0/api-keys
```

Expected: the page loads the current `llm` agent; the `front-desk` URI is absent from the link.
