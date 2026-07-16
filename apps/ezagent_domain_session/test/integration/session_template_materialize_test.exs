defmodule EzagentDomainInstanceMessage.Integration.SessionTemplateMaterializeTest do
  @moduledoc """
  Rev6 SessionTemplate materialization gate.

  `create_session/3` materializes template metadata and declared members, but
  does not spawn or join declared role members. Routing resolves `role:
  <name>` receivers at send-time and provisions the member lazily.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Invocation, KindRegistry, Message}
  alias Ezagent.ActionSet.Session, as: SessionBehavior
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Entity.{SessionTemplate, User}
  alias Ezagent.Routing.Matcher

  defp uniq, do: System.unique_integer([:positive])

  setup do
    _ = Ezagent.SpawnRegistry.spawn(User.admin_uri())

    on_exit(fn ->
      table = Ezagent.Routing.Resolver.default_routing_table()

      try do
        Ezagent.Routing.RuleStore.load_into_registry(table)
      rescue
        _ -> :ok
      end
    end)

    :ok
  end

  test "create records declared members and installs route rules without spawning them" do
    n = uniq()
    role_name = "relay-#{n}"
    tpl_ref = "relay_tpl_#{n}"
    source_template_uri = seed_agent_template(n)
    template_name = "relay-team-#{n}"

    persist_template(relay_team_content(template_name, source_template_uri, role_name, tpl_ref))

    assert {:ok, session_uri, %{}} =
             EzagentDomainInstanceMessage.SessionCreator.create_session(
               "relay-sess-#{n}",
               User.admin_uri(),
               template_name: template_name
             )

    cleanup_session(session_uri)

    slice = chat_slice(session_uri)
    assert SessionBehavior.role_name_to_uri(slice.members, role_name) == nil
    assert slice.prompt_templates[tpl_ref] == "relay: {body}"

    wc = Ezagent.Entity.Session.read_template_working_copy(session_uri)

    assert [
             %{
               role_name: ^role_name,
               in_session_template: true,
               source_template_uri: ^source_template_uri
             }
           ] = wc.member_declarations

    refute Map.has_key?(wc, :orchestrator_template_uri)
    refute Map.has_key?(wc, :orchestrator_uri)

    rows = rule_rows(session_uri)
    assert length(rows) == 1
    assert [%{receivers: stored_receivers}] = rows

    assert Enum.map(stored_receivers, &Ezagent.Routing.Receiver.decode_from_store/1) == [
             {:role, role_name}
           ]
  end

  test "first matching send provisions the declared role member lazily" do
    n = uniq()
    role_name = "worker-#{n}"
    source_template_uri = seed_agent_template(n)
    template_name = "lazy-team-#{n}"

    persist_template(
      relay_team_content(template_name, source_template_uri, role_name, "tpl_#{n}")
    )

    assert {:ok, session_uri, %{}} =
             EzagentDomainInstanceMessage.SessionCreator.create_session(
               "lazy-sess-#{n}",
               User.admin_uri(),
               template_name: template_name
             )

    cleanup_session(session_uri)
    assert role_member_uri(session_uri, role_name) == nil

    assert :ok = dispatch_send(session_uri, "wake role")

    assert wait_until(fn ->
             case role_member_uri(session_uri, role_name) do
               %URI{} = member_uri ->
                 cleanup_agent(member_uri)
                 slice = chat_slice(session_uri)

                 match?(
                   %{online: true, source_template_uri: ^source_template_uri},
                   Map.get(slice.members, member_uri)
                 )

               nil ->
                 false
             end
           end)
  end

  test "two sessions from one template provision distinct member URIs" do
    n = uniq()
    role_name = "worker-#{n}"
    source_template_uri = seed_agent_template(n)
    template_name = "iso-team-#{n}"

    persist_template(
      relay_team_content(template_name, source_template_uri, role_name, "tpl_#{n}")
    )

    assert {:ok, session_a, %{}} =
             EzagentDomainInstanceMessage.SessionCreator.create_session(
               "iso-a-#{n}",
               User.admin_uri(),
               template_name: template_name
             )

    assert {:ok, session_b, %{}} =
             EzagentDomainInstanceMessage.SessionCreator.create_session(
               "iso-b-#{n}",
               User.admin_uri(),
               template_name: template_name
             )

    cleanup_session(session_a)
    cleanup_session(session_b)

    assert :ok = dispatch_send(session_a, "wake A")
    assert :ok = dispatch_send(session_b, "wake B")

    assert wait_until(fn -> match?(%URI{}, role_member_uri(session_a, role_name)) end)
    assert wait_until(fn -> match?(%URI{}, role_member_uri(session_b, role_name)) end)

    member_a = role_member_uri(session_a, role_name)
    member_b = role_member_uri(session_b, role_name)
    cleanup_agent(member_a)
    cleanup_agent(member_b)

    assert Ezagent.URI.type?(member_a, :agent)
    assert Ezagent.URI.type?(member_b, :agent)
    refute member_a == member_b
  end

  test "re-materializing metadata is idempotent and does not provision members" do
    n = uniq()
    role_name = "worker-#{n}"
    source_template_uri = seed_agent_template(n)
    template_name = "idem-team-#{n}"
    content = relay_team_content(template_name, source_template_uri, role_name, "tpl_#{n}")

    persist_template(content)

    assert {:ok, session_uri, %{}} =
             EzagentDomainInstanceMessage.SessionCreator.create_session(
               "idem-sess-#{n}",
               User.admin_uri(),
               template_name: template_name
             )

    cleanup_session(session_uri)
    assert role_member_uri(session_uri, role_name) == nil
    assert length(rule_rows(session_uri)) == 1

    assert :ok =
             EzagentDomainInstanceMessage.materialize_template_team(
               session_uri,
               Ezagent.URI.workspace(:system),
               User.admin_uri(),
               content
             )

    assert :ok =
             EzagentDomainInstanceMessage.materialize_template_team(
               session_uri,
               Ezagent.URI.workspace(:system),
               User.admin_uri(),
               content
             )

    assert role_member_uri(session_uri, role_name) == nil
    assert length(rule_rows(session_uri)) == 1
  end

  test "bad source template does not make create_session fail" do
    n = uniq()
    role_name = "bad-#{n}"
    bad_source = seed_agent_template_no_flavor(n)
    template_name = "bad-source-team-#{n}"

    persist_template(relay_team_content(template_name, bad_source, role_name, "tpl_#{n}"))

    assert {:ok, session_uri, %{}} =
             EzagentDomainInstanceMessage.SessionCreator.create_session(
               "bad-source-sess-#{n}",
               User.admin_uri(),
               template_name: template_name
             )

    cleanup_session(session_uri)
    assert role_member_uri(session_uri, role_name) == nil

    wc = Ezagent.Entity.Session.read_template_working_copy(session_uri)
    assert [%{source_template_uri: ^bad_source}] = wc.member_declarations
  end

  test "a template with a dangling role receiver still fails materialization cleanly" do
    n = uniq()
    template_name = "dangle-team-#{n}"
    role_name = "worker-#{n}"
    source_template_uri = seed_agent_template(n)

    content =
      relay_team_content(template_name, source_template_uri, role_name, "tpl_#{n}")
      |> Map.put(:routing_rules, [
        %{
          matcher: Matcher.mention("trigger-#{n}"),
          receivers: ["ghost-role-#{n}"],
          rule_set: "rs-#{n}",
          position: 0,
          prompt_template_ref: nil
        }
      ])

    persist_template(content)

    assert {:error, reason} =
             EzagentDomainInstanceMessage.SessionCreator.create_session(
               "dangle-sess-#{n}",
               User.admin_uri(),
               template_name: template_name
             )

    assert match?({:install_rule_failed, _rule, {:unknown_rule_receiver, _}}, reason) or
             (is_tuple(reason) and elem(reason, 0) == :install_rule_failed)
  end

  defp relay_team_content(name, source_template_uri, role_name, tpl_ref) do
    %{
      name: name,
      description: "relay team",
      default_workspace_uri: Ezagent.URI.workspace(:system),
      parent_template_uri: nil,
      version_tag: nil,
      created_by: User.admin_uri(),
      created_at: ~U[2026-06-23 00:00:00Z],
      members: [
        %{
          uri: nil,
          role_name: role_name,
          in_session_template: true,
          source_template_uri: source_template_uri
        }
      ],
      prompt_templates: %{tpl_ref => "relay: {body}"},
      legends: %{},
      routing_rules: [
        %{
          matcher: Matcher.from(User.admin_uri()),
          receivers: [role_name],
          rule_set: nil,
          position: 0,
          prompt_template_ref: tpl_ref
        }
      ]
    }
  end

  defp persist_template(content) do
    hash = SessionTemplate.compute_version_hash(content)

    :ok =
      KindSnapshot.delete(
        URI.to_string(SessionTemplate.build_uri(content.name, hash, workspace: "system"))
      )

    {:ok, uri} = SessionTemplate.persist_version_as_system(content, "system")

    on_exit(fn ->
      case KindRegistry.lookup(uri) do
        {:ok, pid} ->
          if Process.alive?(pid),
            do:
              DynamicSupervisor.terminate_child(
                EzagentDomainInstanceMessage.SessionTemplateSupervisor,
                pid
              )

        :error ->
          :ok
      end
    end)

    uri
  end

  defp seed_agent_template(n),
    do: write_agent_template("seed-agent-#{n}", %{flavor: "cc", project_cwd: "/tmp"})

  defp seed_agent_template_no_flavor(n), do: write_agent_template("seed-bad-agent-#{n}", %{})

  defp write_agent_template(name, extra) do
    uri = Ezagent.URI.new!("template://system/agent/#{name}")
    {:ok, _} = Ezagent.SpawnRegistry.spawn(uri)
    admin = User.admin_uri()
    target = URI.new!("#{URI.to_string(uri)}?action=template.write")
    {:ok, signed_cap} = Ezagent.Cap.issue_for_action({:admin, admin}, admin, target)

    {:ok, _} =
      Invocation.dispatch(%Invocation{
        origin: :trusted_internal,
        target: target,
        mode: :call,
        args: %{
          content:
            Map.merge(
              %{
                project_cwd: "/tmp",
                default_caps: [],
                created_by: User.admin_uri(),
                created_at: ~U[2026-06-23 00:00:00Z]
              },
              extra
            )
        },
        ctx: %{
          caller: admin,
          caps: MapSet.new([signed_cap]),
          reply: {:caller_inbox, self()}
        }
      })

    on_exit(fn -> cleanup_template(uri) end)
    uri
  end

  defp chat_slice(session_uri) do
    {:ok, pid} = KindRegistry.lookup(session_uri)
    %{state: %{session: %{state: slice}}} = :sys.get_state(pid)
    slice
  end

  defp role_member_uri(session_uri, role_name) do
    session_uri
    |> chat_slice()
    |> Map.get(:members, %{})
    |> SessionBehavior.role_name_to_uri(role_name)
  end

  defp dispatch_send(session_uri, text) do
    msg = Message.new(User.admin_uri(), %{text: text, attachments: []})
    admin = User.admin_uri()
    target = URI.new!("#{URI.to_string(session_uri)}?action=session.send")
    {:ok, signed_cap} = Ezagent.Cap.issue_for_action({:admin, admin}, admin, target)

    Invocation.dispatch(%Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :cast,
      args: %{message: msg},
      ctx: %{
        caller: admin,
        caps: MapSet.new([signed_cap]),
        reply: :ignore
      }
    })
  end

  defp rule_rows(session_uri) do
    table = Ezagent.Routing.Resolver.default_routing_table()
    session_str = URI.to_string(session_uri)

    Ezagent.Routing.RuleStore.list(table)
    |> Enum.filter(&(&1.created_by == session_str))
  end

  defp wait_until(fun, retries \\ 50)

  defp wait_until(fun, retries) do
    case fun.() do
      false when retries > 0 ->
        Process.sleep(10)
        wait_until(fun, retries - 1)

      result ->
        result
    end
  end

  defp cleanup_session(%URI{} = uri) do
    on_exit(fn -> terminate_if_alive(EzagentDomainInstanceMessage.SessionSupervisor, uri) end)
  end

  defp cleanup_agent(%URI{} = uri) do
    on_exit(fn -> terminate_if_alive(EzagentDomainInstanceMessage.AgentSupervisor, uri) end)
  end

  defp cleanup_template(%URI{} = uri) do
    terminate_if_alive(EzagentDomainInstanceMessage.AgentTemplateSupervisor, uri)
  end

  defp terminate_if_alive(supervisor, uri) do
    case KindRegistry.lookup(uri) do
      {:ok, pid} when is_pid(pid) ->
        if Process.alive?(pid), do: DynamicSupervisor.terminate_child(supervisor, pid)

      _ ->
        :ok
    end
  end
end
