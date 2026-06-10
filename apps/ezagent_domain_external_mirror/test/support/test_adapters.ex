defmodule Ezagent.ExternalMirror.TestSupport.MockAdapter.Allow do
  @moduledoc """
  Per-adapter Allow Behavior for `MockAdapter` (PR-EM-3 Check 2 cap
  shape). Cap-only — `dispatchable?/0 == false` so dispatch can never
  accidentally invoke it.

  Registered against `Ezagent.Entity.Session` with action
  `:allow_mock_em` by `EzagentDomainExternalMirror.Application.start/2`.
  """
  @behaviour Ezagent.Behavior

  @impl true
  def actions, do: [:allow_mock_em]

  @impl true
  def cap_subjects,
    do: [{:allow_mock_em, "Authorize binding the `mock_em` adapter on this session."}]

  @impl true
  def dispatchable?, do: false

  @impl true
  def state_slice, do: :external_adapter_mock_em

  @impl true
  def init_slice(_args), do: %{}

  @impl true
  def invoke(_action, _slice, _args, _ctx) do
    raise "MockAdapter.Allow is cap-only — Check 2 in the bind facade is its only consumer."
  end

  @impl true
  def interface, do: %{}

  @impl true
  def required_caps,
    do: %{allow_mock_em: Ezagent.Capability.cap(:session, __MODULE__, :allow_mock_em)}

  # `:any` → workspace admin grants per caps-data-ownership §3.3.
  @impl true
  def data_owner(_), do: :any
end

defmodule Ezagent.ExternalMirror.TestSupport.OtherAdapter.Allow do
  @moduledoc "Paired with `OtherAdapter` (collision tests share the adapter_id so this is functionally identical to MockAdapter.Allow above, but kept distinct for module-identity tests)."
  @behaviour Ezagent.Behavior

  @impl true
  def actions, do: [:allow_mock_em]

  @impl true
  def cap_subjects,
    do: [{:allow_mock_em, "Authorize binding the other-adapter shape on this session."}]

  @impl true
  def dispatchable?, do: false

  @impl true
  def state_slice, do: :external_adapter_other_em

  @impl true
  def init_slice(_args), do: %{}

  @impl true
  def invoke(_action, _slice, _args, _ctx) do
    raise "OtherAdapter.Allow is cap-only."
  end

  @impl true
  def interface, do: %{}

  @impl true
  def required_caps,
    do: %{allow_mock_em: Ezagent.Capability.cap(:session, __MODULE__, :allow_mock_em)}

  @impl true
  def data_owner(_), do: :any
end

defmodule Ezagent.ExternalMirror.TestSupport.MockAdapter do
  @moduledoc """
  In-test mock Adapter for the AdapterRegistry / BindingRegistry /
  facade / plugin-contract tests (PR-EM-1 + PR-EM-2).

  Implements the full PR-EM-2 callback set per SPEC §2.2. The
  publish-side callbacks (`event_to_payload/1`) are intentionally
  no-op echoes so the same mock works for both registry tests
  (where the callbacks are never invoked) and Worker-flow tests
  (PR-EM-2's mock-adapter test support uses a richer per-pid echo
  mock — `apps/ezagent_domain_external_mirror/test/support/mock_publish_adapter.ex`).
  """
  @behaviour Ezagent.ExternalMirror.Adapter

  @impl true
  def adapter_id, do: "mock_em"

  @impl true
  def display_name, do: "Mock EM Adapter"

  @impl true
  def description, do: "Test-only adapter for PR-EM-1 registry tests."

  @impl true
  def binding_module, do: Ezagent.ExternalMirror.TestSupport.MockBinding

  # ----- PR-EM-2 additions --------------------------------------------------

  @impl true
  def cap_subject do
    %{
      behavior_module: Ezagent.ExternalMirror.TestSupport.MockAdapter.Allow,
      description: "Test-only adapter-allow cap (PR-EM-2 registry tests)."
    }
  end

  @impl true
  def target_ownership_check(_caller, _target_id), do: :ok

  @impl true
  def event_to_payload(%Ezagent.Publisher.Event{} = event),
    do: {:publish, %{echo: event}}
end

defmodule Ezagent.ExternalMirror.TestSupport.MockBinding do
  @moduledoc """
  In-test mock Binding paired with `MockAdapter`. Implements the
  full PR-EM-2 callback set per SPEC §2.3 — `init/1` returns
  the options map verbatim, `publish/2` is a no-op success, and
  `terminate/2` is the optional no-op default.
  """
  @behaviour Ezagent.ExternalMirror.Binding

  @impl true
  def adapter_module, do: Ezagent.ExternalMirror.TestSupport.MockAdapter

  # ----- PR-EM-2 additions --------------------------------------------------

  @impl true
  def init({_target_id, _adapter, options}), do: {:ok, options}

  @impl true
  def publish(_payload, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok
end

defmodule Ezagent.ExternalMirror.TestSupport.OtherAdapter do
  @moduledoc "A second adapter for collision tests — same id as MockAdapter."
  @behaviour Ezagent.ExternalMirror.Adapter

  @impl true
  def adapter_id, do: "mock_em"

  @impl true
  def display_name, do: "Other EM Adapter (same id)"

  @impl true
  def description, do: "Second adapter claiming the same id — should be rejected."

  @impl true
  def binding_module, do: Ezagent.ExternalMirror.TestSupport.OtherBinding

  # ----- PR-EM-2 additions --------------------------------------------------

  @impl true
  def cap_subject do
    %{
      behavior_module: Ezagent.ExternalMirror.TestSupport.OtherAdapter.Allow,
      description: "Other test adapter cap subject."
    }
  end

  @impl true
  def target_ownership_check(_caller, _target_id), do: :ok

  @impl true
  def event_to_payload(%Ezagent.Publisher.Event{} = event),
    do: {:publish, %{echo: event}}
end

defmodule Ezagent.ExternalMirror.TestSupport.OtherBinding do
  @moduledoc "Paired binding for OtherAdapter."
  @behaviour Ezagent.ExternalMirror.Binding

  @impl true
  def adapter_module, do: Ezagent.ExternalMirror.TestSupport.OtherAdapter

  # ----- PR-EM-2 additions --------------------------------------------------

  @impl true
  def init({_target_id, _adapter, options}), do: {:ok, options}

  @impl true
  def publish(_payload, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok
end

defmodule Ezagent.ExternalMirror.TestSupport.PullAdapter.Allow do
  @moduledoc """
  Per-adapter Allow Behavior for the P3-1 `:pull` test adapter. Cap-only
  (`dispatchable?/0 == false`), mirroring `MockAdapter.Allow`. A `:pull`
  adapter still declares a `cap_subject/0` so the per-adapter authorization
  cap shape exists.
  """
  @behaviour Ezagent.Behavior

  @impl true
  def actions, do: [:allow_pull_em]

  @impl true
  def cap_subjects,
    do: [{:allow_pull_em, "Authorize the `pull_em` pull adapter on this session."}]

  @impl true
  def dispatchable?, do: false

  @impl true
  def state_slice, do: :external_adapter_pull_em

  @impl true
  def init_slice(_args), do: %{}

  @impl true
  def invoke(_action, _slice, _args, _ctx) do
    raise "PullAdapter.Allow is cap-only."
  end

  @impl true
  def interface, do: %{}

  @impl true
  def required_caps,
    do: %{allow_pull_em: Ezagent.Capability.cap(:session, __MODULE__, :allow_pull_em)}

  @impl true
  def data_owner(_), do: :any
end

defmodule Ezagent.ExternalMirror.TestSupport.PullAdapter do
  @moduledoc """
  P3-1 `:pull` test adapter. A pull adapter has NO per-binding external
  transport — it is served by its caller's Phoenix channel (P3-2), so it
  declares NO `binding_module/0`, NO `target_ownership_check/2`, and NO
  `event_to_payload/1`. It declares `adapter_kind/0 == :pull` plus the
  pull-only `render/2` callback and the shared `cap_subject/0`.

  Asserts the P3-1 contract: a `:pull` adapter registers without a binding
  and without spawning a Worker.
  """
  @behaviour Ezagent.ExternalMirror.Adapter

  @impl true
  def adapter_id, do: "pull_em"

  @impl true
  def display_name, do: "Pull EM Adapter"

  @impl true
  def description, do: "Test-only pull adapter for P3-1 (Phoenix-channel feed)."

  @impl true
  def adapter_kind, do: :pull

  @impl true
  def cap_subject do
    %{
      behavior_module: Ezagent.ExternalMirror.TestSupport.PullAdapter.Allow,
      description: "Test-only pull-adapter-allow cap (P3-1)."
    }
  end

  @impl true
  def render(%URI{} = session_uri, ctx) when is_map(ctx) do
    %{session_uri: URI.to_string(session_uri), ctx: ctx}
  end
end

defmodule Ezagent.ExternalMirror.TestSupport.PushAdapterMissingBinding do
  @moduledoc """
  A `:push` adapter (the back-compat default kind — it does NOT export
  `adapter_kind/0`) that is MISSING `binding_module/0`. P3-1 asserts the
  registry still rejects it: a push adapter without a binding is a
  structural error.
  """
  @behaviour Ezagent.ExternalMirror.Adapter

  @impl true
  def adapter_id, do: "push_missing_binding_em"

  @impl true
  def display_name, do: "Push Adapter Missing Binding"

  @impl true
  def description, do: "Test-only push adapter with no binding — must be rejected."

  @impl true
  def cap_subject do
    %{
      behavior_module: Ezagent.ExternalMirror.TestSupport.MockAdapter.Allow,
      description: "Reused cap subject for the missing-binding push test."
    }
  end

  @impl true
  def target_ownership_check(_caller, _target_id), do: :ok

  @impl true
  def event_to_payload(%Ezagent.Publisher.Event{} = event), do: {:publish, %{echo: event}}

  # Intentionally NO `binding_module/0`.
end
