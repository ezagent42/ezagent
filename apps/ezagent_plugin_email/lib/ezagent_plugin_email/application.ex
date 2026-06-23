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

  ## PR-2 declarations (inbound)

  - `children/0` → `[Ezagent.Email.Inbound]` — the inbound poll loop.
    Skipped at test boot (`Mix.env() == :test`), mirroring Feishu's
    `maybe_ws_client_spec/0`, so the suite doesn't run a live poller / leak
    network calls to the CF Worker.
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

  # #88 PR-2 (§4.7) — the inbound poll loop. Skipped at test boot so the
  # suite doesn't run a live poller or hit the CF Worker (mirrors Feishu's
  # `maybe_ws_client_spec/0`).
  @impl Ezagent.Plugin
  def children, do: Enum.reject([maybe_inbound_spec()], &is_nil/1)

  defp maybe_inbound_spec do
    if Code.ensure_loaded?(Mix) and Mix.env() == :test do
      nil
    else
      Ezagent.Email.Inbound
    end
  end
end
