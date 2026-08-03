defmodule Ezagent.Entity.Agent.TemplateSpawn.CascadeCredentialOptionalTest do
  @moduledoc """
  content-level `credential_optional` override (protects INV-CC: deployments
  with no DeepSeek credential source must still be able to create sessions).

  Exercised through a FAKE slice-credentialled Template Class (like the sibling
  `credential_status_test.exs`'s `SliceTC`) rather than the real
  `Ezagent.PluginCurlAgent.Template` — `ezagent_domain_agent` deliberately has
  no compile dep on any plugin (see this app's mix.exs), so the plugin module
  is not on the code path when this app's tests run in isolation
  (`Code.ensure_loaded/1` fails silently and `credentialled?/1` reports
  `false`, masking the very branch under test). A fake `@behaviour
  Ezagent.Agent.CredentialSliceAdapter` module keeps the test inside the
  domain/plugin isolation seam while still exercising the real `:slice`
  adapter-kind detection in `cascade.ex`.

  The `:config_dir` `Ezagent.UriQuery` attribute has a SINGLE owner
  (`EzagentDomainInstanceMessage`, in `ezagent_domain_session`) which
  `ezagent_domain_agent` deliberately does not depend on (same tier-boundary
  rule as above). Without that owner loaded, resolving any layer source
  through the real cascade would hit `{:error, {:no_resolver, :config_dir}}`
  — an isolation artifact, not a `credential_optional` behavior. Register a
  local stub that reports "no config dir for this URI" (`:none`), which is
  also the domain-honest answer for a slice-credentialled flavor (it has no
  file-based config at all). Idempotent against a real owner already being
  registered (full-umbrella test runs).
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.Agent.TemplateSpawn.Cascade

  # A slice-credentialled fake flavor (like curl) — creds in the :api_keys slice.
  defmodule SliceTC do
    @behaviour Ezagent.Agent.CredentialSliceAdapter
    def credential_slice, do: :api_keys
    def materialize_credential_slice(_uri, _data), do: :ok
  end

  @agent Ezagent.URI.entity("system", :agent, "cred-opt-demo")
  @admin Ezagent.Entity.User.admin_uri()
  @ws Ezagent.URI.workspace(:system)
  @source_tmpl Ezagent.URI.template(:system, :agent, "hello.llm")

  setup_all do
    case Ezagent.UriQuery.register(:config_dir, fn _ -> :none end) do
      :ok -> :ok
      {:error, {:already_registered, :config_dir}} -> :ok
    end

    :ok
  end

  test "credential_optional: true → :slice agent resolves keyless (no :no_credential_source) when no source" do
    content = %{
      name: "cred-opt-demo",
      flavor: "curl",
      credential_optional: true,
      provider: "deepseek",
      api_url: "https://api.deepseek.com/chat/completions",
      model: "deepseek-chat"
    }

    assert {:ok, resolved} =
             Cascade.resolve_content(content, SliceTC, @agent, @admin, @ws, "curl",
               source_template_uri: @source_tmpl
             )

    # keyless: no credential source got written into the resolution
    refute Map.get(resolved, :cascade_resolution) &&
             Map.get(resolved.cascade_resolution, :credential_source_uri)
  end

  test "without credential_optional → :slice with no source still fails (regression: existing curl unchanged)" do
    content = %{
      name: "req-demo",
      flavor: "curl",
      provider: "deepseek",
      api_url: "https://api.deepseek.com/chat/completions",
      model: "deepseek-chat"
    }

    assert {:error, :no_credential_source} =
             Cascade.resolve_content(content, SliceTC, @agent, @admin, @ws, "curl",
               source_template_uri: @source_tmpl
             )
  end

  test "session-local source policy bypasses reusable credential lookups" do
    content = %{
      name: "session-local-demo",
      flavor: "curl",
      provider: "deepseek",
      api_url: "https://api.deepseek.com/chat/completions",
      model: "deepseek-chat",
      cascade_resolution: %{
        owner_uri: @admin,
        workspace_uri: @ws,
        flavor: "curl",
        credential_required?: true,
        credential_source_policy: :session_local,
        user_source_lookup: fn -> flunk("user source must not be read") end,
        workspace_shared_lookup: fn -> flunk("workspace source must not be read") end
      }
    }

    assert {:ok, resolved} =
             Cascade.resolve_content(content, SliceTC, @agent, @admin, @ws, "curl",
               source_template_uri: @source_tmpl
             )

    refute Map.get(resolved.cascade_resolution, :credential_source_uri)
  end

  test "top-level session-local policy replaces a pre-authored credential cascade" do
    old_source = Ezagent.URI.entity("system", :agent, "old-credential-source")

    content = %{
      name: "session-local-authored-cascade",
      flavor: "curl",
      credential_optional: true,
      credential_source_policy: :session_local,
      cascade: %{
        layer_dirs: [%{dir: "/tmp/reused-credential-layer"}],
        source_dir_for: fn _ -> {:ok, "/tmp/reused-credential-source"} end,
        pending_grant: %{source: old_source}
      }
    }

    assert {:ok, resolved} =
             Cascade.resolve_content(content, SliceTC, @agent, @admin, @ws, "curl",
               source_template_uri: @source_tmpl
             )

    assert resolved.cascade.layer_dirs == []
    refute Map.has_key?(resolved.cascade, :pending_grant)
    assert resolved.cascade_resolution.credential_source_policy == :session_local
  end

  test "top-level session-local policy sanitizes a nested authored resolution" do
    old_source = Ezagent.URI.entity("system", :agent, "nested-old-credential-source")

    content = %{
      name: "session-local-authored-resolution",
      flavor: "curl",
      credential_optional: true,
      credential_source_policy: :session_local,
      cascade_resolution: %{
        owner_uri: @admin,
        workspace_uri: @ws,
        flavor: "curl",
        credential_required?: true,
        explicit_source: old_source,
        credential_source_uri: old_source,
        pending_grant: %{source: old_source},
        user_source_lookup: fn -> flunk("user source must not be read") end,
        workspace_shared_lookup: fn -> flunk("workspace source must not be read") end
      }
    }

    assert {:ok, resolved} =
             Cascade.resolve_content(content, SliceTC, @agent, @admin, @ws, "curl",
               source_template_uri: @source_tmpl
             )

    resolution = resolved.cascade_resolution
    assert resolution.credential_source_policy == :session_local
    refute Map.has_key?(resolution, :explicit_source)
    refute Map.has_key?(resolution, :credential_source_uri)
    refute Map.has_key?(resolution, :pending_grant)
    refute Map.has_key?(resolved.cascade, :pending_grant)
  end

  test "session-local default resolution keeps non-secret cascade layers" do
    content = %{
      name: "session-local-default-layers",
      flavor: "curl",
      credential_optional: true,
      credential_source_policy: :session_local
    }

    assert {:ok, resolved} =
             Cascade.resolve_content(content, SliceTC, @agent, @admin, @ws, "curl",
               source_template_uri: @source_tmpl
             )

    assert %{layer_dirs: [], source_dir_for: source_dir_for} = resolved.cascade
    assert is_function(source_dir_for, 1)
    assert resolved.cascade_resolution.workspace_layer_uri == @source_tmpl
    assert resolved.cascade_resolution.credential_source_policy == :session_local
    refute Map.has_key?(resolved.cascade_resolution, :credential_source_uri)
  end
end
