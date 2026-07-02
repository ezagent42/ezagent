defmodule EzagentPluginHello.Behavior.HelloRender do
  @moduledoc """
  T2-2a — the hello socialware's **view read ActionSet** (views-as-behavior).

  A view is a render ActionSet that declares a UNIQUE `<sw>_render` read action
  — here `:hello_render`. It is **cap-only** (`dispatchable?/0 → false`, no
  dispatch interface): it exists solely so a `<sw>_render` capability can be
  DECLARED + registered on the Session Kind and checked by
  `Ezagent.UI.SessionView.authorize_view/3` (T2-2b). The precedent is
  `Ezagent.Socialware.ExternalFeedAdapter.Allow` — an auth gate with no
  dispatchable surface.

  ## Why a UNIQUE action name (Allen decision 1 = a)

  All views hang off the Session Kind, and the dispatch/cap route table is keyed
  `{kind, action}` with `{kind, action}`-uniqueness (`CapabilityRegistry.check_conflict!`
  RAISES on a second behavior claiming the same pair). A shared `:render` action
  would collide the moment two views (hello + kanban) register. `:hello_render`
  vs `:kanban_render` keep `{Session, :hello_render}` / `{Session, :kanban_render}`
  distinct. The `<sw>_` business-prefix lives in the product plugin, not the
  platform layer.

  > **Rebase note (T1):** authored against the current `Ezagent.Behavior` name;
  > the coordinator renames `Ezagent.Behavior` → `Ezagent.ActionSet` at the T1
  > rebase (this becomes a view ActionSet).
  """

  use Ezagent.Lifecycle

  @impl Ezagent.Behavior
  def actions, do: [:hello_render]

  @impl Ezagent.Behavior
  def cap_subjects,
    do: [{:hello_render, "Read (render) the hello socialware page view for this session."}]

  @impl Ezagent.Behavior
  def dispatchable?, do: false

  @impl Ezagent.Behavior
  def interface, do: %{}

  @impl Ezagent.Behavior
  def required_caps,
    do: %{hello_render: Ezagent.Capability.cap(:session, __MODULE__, :hello_render)}

  @impl Ezagent.Behavior
  def data_owner(_), do: :any
end
