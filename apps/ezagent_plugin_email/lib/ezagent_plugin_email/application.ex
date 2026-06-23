defmodule EzagentPluginEmail.Application do
  @moduledoc """
  Email plugin OTP application + `Ezagent.Plugin` contract module (task #88).

  It owns the ezagent.chat email capability — `Ezagent.Email` send (Swoosh
  SMTP) / receive (CF Email Worker pull over `:httpc`) — exposed through a
  `mix ezagent.email` CLI, AND (#88 PR-1) the **email external-mirror
  adapter** that mirrors session chat OUT to a bound email address.

  ## PR-1 declarations (outbound-only)

  - `adapters/0` → `{Ezagent.Email.Adapter, Ezagent.Email.Binding}` — the
    generic ExternalMirror `:push` pair. `Ezagent.Plugin.boot/1` enforces
    Grill-5 (bidirectional declaration, distinct modules) and auto-registers
    the per-adapter cap subject via `AdapterInstall.install/1`.
  - `behaviors/0` → registers the cap-only marker
    `EzagentPluginEmail.Behavior.ExternalAdapter.Email.Allow` on the Session
    Kind for `:allow_email`, satisfying `AdapterCapSubjectRegisteredTest`
    (a real registered `behavior_module`, not the `nil` opt-out).

  ## NOT in PR-1

  No `children/0` — the inbound poll loop (`Ezagent.Email.Inbound`) lands in
  PR-2, gated on the addressing/verification/auth/dedup work. PR-1 makes no
  bidirectional-complete claim and is production-inert until PR-2 mints
  `:verified` bindings.
  """
  use Application
  use Ezagent.Plugin

  alias Ezagent.Entity.Session, as: SessionKind
  alias Ezagent.Email.{Adapter, Binding}
  alias EzagentPluginEmail.Behavior.ExternalAdapter.Email.Allow, as: EmailAllow

  @impl Application
  def start(_type, _args), do: Ezagent.Plugin.boot(__MODULE__)

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "email",
      name: "Email",
      description: "ezagent.chat email send/receive + outbound external-mirror adapter.",
      version: "0.1.0"
    }
  end

  # #88 PR-1 (MED 7 / §4.7) — register the cap-only marker on the Session
  # Kind for each of its actions, exactly like Feishu's application.ex. This
  # is what keeps `AdapterCapSubjectRegisteredTest` green: the cap_subject's
  # behavior_module is a REAL registered `(Session, :allow_email, Allow)`
  # triple, not a never-registered reference.
  @impl Ezagent.Plugin
  def behaviors do
    for action <- EmailAllow.actions() do
      {SessionKind, action, EmailAllow}
    end
  end

  # #88 PR-1 (§4.7) — declare the generic ExternalMirror `:push` pair.
  # `Ezagent.Plugin.boot/1` enforces Grill-5 + registers both with
  # AdapterRegistry + BindingRegistry; the cap subject is auto-registered
  # via `AdapterInstall.install/1` once the adapter lands in AdapterRegistry.
  @impl Ezagent.Plugin
  def adapters, do: [{Adapter, Binding}]
end
