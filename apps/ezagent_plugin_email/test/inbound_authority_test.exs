defmodule Ezagent.Email.Inbound.AuthorityTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Email.InboundBinding
  alias Ezagent.Email.Inbound.Authority
  alias Ezagent.ExternalMirror.BindingRow
  alias EzagentCore.Repo

  defmodule RaisingReader do
    def read(_local_address), do: raise("reader unavailable")
  end

  @workspace "workspace://system"

  setup do
    authority_config = Application.fetch_env(:ezagent_plugin_email, Authority)
    cap_config = Application.fetch_env!(:ezagent_core, Ezagent.Cap)

    on_exit(fn ->
      restore_env(:ezagent_plugin_email, Authority, authority_config)
      Application.put_env(:ezagent_core, Ezagent.Cap, cap_config)
    end)

    :ok
  end

  defp binding_fixture(status \\ :verified) do
    suffix = System.unique_integer([:positive])
    session_uri = Ezagent.URI.new!("session://system/default/authority-#{suffix}")
    target = "authority-#{suffix}@example.com"
    local = "authority-#{suffix}@ezagent.chat"
    row_id = BindingRow.row_id(session_uri, "email", target)

    {:ok, row} =
      BindingRow.insert(%{
        id: row_id,
        session_uri: URI.to_string(session_uri),
        adapter_id: "email",
        target_id: target,
        opts_json: "{}",
        bound_by: "entity://system/user/admin",
        bound_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
        workspace_uri: @workspace
      })

    {:ok, {meta, _token}} =
      InboundBinding.record(%{
        binding_row_id: row_id,
        local_address: local,
        session_uri: URI.to_string(session_uri),
        target_id: target,
        workspace_uri: @workspace
      })

    meta =
      if status == :verified do
        {:ok, meta} = InboundBinding.mark_verified(row_id)
        meta
      else
        meta
      end

    %{row: row, meta: meta, session_uri: session_uri, target: target, local: local}
  end

  defp record(fixture, overrides \\ %{}) do
    Map.merge(
      %{
        "to" => fixture.local,
        "from" => fixture.target,
        "authResults" => "spf=pass dkim=pass dmarc=pass"
      },
      overrides
    )
  end

  test "an address without durable binding evidence is rejected" do
    assert {:reject, :no_binding} =
             Authority.issue(%{
               "to" => "missing-#{System.unique_integer([:positive])}@ezagent.chat",
               "from" => "human@example.com",
               "authResults" => "spf=pass dkim=pass dmarc=pass"
             })
  end

  test "an unverified projection is rejected" do
    fixture = binding_fixture(:pending)
    assert {:reject, :not_verified} = Authority.issue(record(fixture))
  end

  test "a projection session mismatch is rejected" do
    fixture = binding_fixture()

    Repo.update!(
      Ecto.Changeset.change(fixture.meta, session_uri: "session://system/default/other")
    )

    assert {:reject, :binding_authority_mismatch} = Authority.issue(record(fixture))
  end

  test "a non-email parent binding is rejected" do
    fixture = binding_fixture()
    Repo.update!(Ecto.Changeset.change(fixture.row, adapter_id: "slack"))
    assert {:reject, :binding_authority_mismatch} = Authority.issue(record(fixture))
  end

  test "a target mismatch is rejected" do
    fixture = binding_fixture()
    Repo.update!(Ecto.Changeset.change(fixture.meta, target_id: "other@example.com"))
    assert {:reject, :binding_authority_mismatch} = Authority.issue(record(fixture))
  end

  test "a projection workspace mismatch is rejected" do
    fixture = binding_fixture()
    Repo.update!(Ecto.Changeset.change(fixture.meta, workspace_uri: "workspace://other"))
    assert {:reject, :binding_authority_mismatch} = Authority.issue(record(fixture))
  end

  test "a workspace outside the session workspace is rejected" do
    fixture = binding_fixture()
    Repo.update!(Ecto.Changeset.change(fixture.meta, workspace_uri: "workspace://other"))
    Repo.update!(Ecto.Changeset.change(fixture.row, workspace_uri: "workspace://other"))
    assert {:reject, :binding_authority_mismatch} = Authority.issue(record(fixture))
  end

  test "a non-entity binding actor is rejected" do
    fixture = binding_fixture()
    Repo.update!(Ecto.Changeset.change(fixture.row, bound_by: "system://bootstrap"))
    assert {:reject, :binding_actor_invalid} = Authority.issue(record(fixture))
  end

  test "current-message authentication and sender remain part of the decision" do
    fixture = binding_fixture()

    assert {:reject, :auth_failed} =
             Authority.issue(record(fixture, %{"authResults" => "dmarc=fail spf=fail"}))

    assert {:reject, :from_mismatch} =
             Authority.issue(record(fixture, %{"from" => "attacker@example.com"}))
  end

  test "reader infrastructure failure is retryable" do
    Application.put_env(:ezagent_plugin_email, Authority, reader: RaisingReader)

    assert {:retry, {:binding_reader_failed, %RuntimeError{message: "reader unavailable"}}} =
             Authority.issue(%{"to" => "any@ezagent.chat"})
  end

  test "deleting the parent binding cascades the projection and removes authority" do
    fixture = binding_fixture()

    assert {:ok, :deleted} = BindingRow.delete_by_id(fixture.row.id)
    assert Repo.get(InboundBinding, fixture.row.id) == nil
    assert {:reject, :no_binding} = Authority.issue(record(fixture))
  end

  test "per-Kind authority load failure is retryable" do
    fixture = binding_fixture()
    seal_without_active_authority!(fixture.session_uri)

    assert {:retry, {:cap_issue_failed, _reason}} = Authority.issue(record(fixture))
  end

  defp seal_without_active_authority!(session_uri) do
    {:ok, _pid} = Ezagent.LocalRuntime.ensure_started(session_uri)
    :ok = Ezagent.Cap.Authority.retire(session_uri)
  end

  defp restore_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore_env(app, key, :error), do: Application.delete_env(app, key)
end
