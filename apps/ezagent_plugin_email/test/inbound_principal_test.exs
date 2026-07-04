defmodule Ezagent.Email.Inbound.PrincipalTest do
  @moduledoc """
  #88 PR-2 (SPEC §4.6 / plan D5) — the restricted inbound participant.

  The honest auth assertion: the minted cap must MATCH (via the real
  `Ezagent.Capability.matches?/2` matcher that dispatch step 5.5 uses) the
  `needed` cap the runtime derives for `Session :send` on THIS session, and
  must NOT match a different session's need. The `needed` map is built here
  independently (mirroring `Kind.Runtime.resolve_required_cap/4`'s
  substitution: declared `Session :send` cap → concrete instance +
  workspace), so the test is not tautological.
  """
  use ExUnit.Case, async: true

  alias Ezagent.Email.Inbound.Principal

  defp session_uri(name \\ "p-#{System.unique_integer([:positive])}") do
    Ezagent.URI.new!("session://system/default/#{name}")
  end

  # The needed-cap shape dispatch step 5.5 derives for `Session :send` on a
  # concrete target (declared behavior `Ezagent.ActionSet.Session`; instance +
  # workspace substituted from the target).
  defp needed_send(%URI{} = su) do
    %{
      kind: :session,
      behavior: Ezagent.ActionSet.Session,
      action: :send,
      instance: Ezagent.URI.instance(su),
      workspace_uri: Ezagent.Capability.workspace_of(su)
    }
  end

  test "mint/1 builds a synthetic entity principal URI in the session workspace" do
    su = session_uri()
    {principal_uri, _caps} = Principal.mint(su)

    assert %URI{scheme: "entity"} = principal_uri
    assert String.starts_with?(URI.to_string(principal_uri), "entity://system/user/email-")
  end

  test "mints EXACTLY one cap" do
    {_uri, caps} = Principal.mint(session_uri())
    assert MapSet.size(caps) == 1
  end

  test "the minted cap authorizes session.send on THIS session (real matcher)" do
    su = session_uri()
    {_uri, caps} = Principal.mint(su)
    [cap] = MapSet.to_list(caps)

    assert Ezagent.Capability.matches?(cap, needed_send(su))
  end

  # Pin the behavior axis to the module the Session Kind actually registers
  # for :send, so a future divergence between the minted cap and the runtime's
  # resolved `needed` shape is caught here. (Full runtime authorization — a
  # real dispatch under this principal — is left to the lead's integration
  # check / live E2E; the email plugin test harness does not boot a live
  # Session Kind tree.)
  test "the minted cap's behavior is the registered Session :send behavior" do
    {_uri, caps} = Principal.mint(session_uri())
    [cap] = MapSet.to_list(caps)

    assert cap.kind == :session
    assert cap.behavior == Ezagent.ActionSet.Session
    assert cap.action == :send
  end

  test "the minted cap is DENIED for a different session (least-privilege)" do
    su = session_uri()
    other = session_uri()
    {_uri, caps} = Principal.mint(su)
    [cap] = MapSet.to_list(caps)

    refute Ezagent.Capability.matches?(cap, needed_send(other))
  end

  test "the minted cap does NOT authorize a different action (e.g. :bind)" do
    su = session_uri()
    {_uri, caps} = Principal.mint(su)
    [cap] = MapSet.to_list(caps)

    needed_bind = %{
      kind: :session,
      behavior: Ezagent.ActionSet.ExternalMirror,
      action: :bind,
      instance: Ezagent.URI.instance(su),
      workspace_uri: Ezagent.Capability.workspace_of(su)
    }

    refute Ezagent.Capability.matches?(cap, needed_bind)
  end

  test "granted_by is the synthetic participant (a real entity URI, #154)" do
    {principal_uri, caps} = Principal.mint(session_uri())
    [cap] = MapSet.to_list(caps)

    assert cap.granted_by == principal_uri
    assert %URI{scheme: "entity"} = cap.granted_by
  end
end
