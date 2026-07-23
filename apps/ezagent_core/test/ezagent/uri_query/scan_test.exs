defmodule Ezagent.UriQuery.ScanTest do
  use ExUnit.Case, async: true

  alias Ezagent.UriQuery.Scan

  describe "scan_paths/1" do
    test "classifies the PR-B flavor-prefix dependency category" do
      path =
        fixture!("flavor_prefix.ex", """
        defmodule Fixture.FlavorPrefix do
          def check_agent_uri(%{"agent_uri" => uri_str}) do
            with {:ok, %URI{scheme: "entity", host: "agent", path: "/" <> rest}} <- Ezagent.Ezagent.URI.new!(uri_str),
                 [_workspace, entity_name] <- String.split(rest, "/", parts: 2),
                 ["cc", _name] <- String.split(entity_name, "_", parts: 2) do
              :ok
            end
          end
        end
        """)

      violations = Scan.scan_paths([path])

      assert [%Scan.Violation{category: :flavor_prefix_dependency, line: line} | _] =
               violations_for(violations, :flavor_prefix_dependency)

      assert line > 0
    end

    test "does not classify sanitized URI filename reconstruction as flavor-prefix dependency" do
      path =
        fixture!("pid_file_uri_reconstruction.ex", """
        defmodule Fixture.PidFileUriReconstruction do
          def parse(base) do
            case String.split(base, "_", parts: 4) do
              ["entity", "agent", workspace, entity_name] ->
                {:ok, {workspace, entity_name}}

              _ ->
                :error
            end
          end
        end
        """)

      violations = Scan.scan_paths([path])

      assert [] = violations_for(violations, :flavor_prefix_dependency)
    end

    test "does not classify ordinary snake_case camelize as flavor-prefix dependency" do
      path =
        fixture!("camelize.ex", """
        defmodule Fixture.Camelize do
          def camelize(name) do
            name
            |> String.split("_")
            |> Enum.map(&String.capitalize/1)
            |> Enum.join("")
          end
        end
        """)

      violations = Scan.scan_paths([path])

      assert [] = violations_for(violations, :flavor_prefix_dependency)
    end

    test "classifies hard-coded flavor prefix binary matches" do
      path =
        fixture!("cc_prefix_pattern.ex", """
        defmodule Fixture.CcPrefixPattern do
          def cc_agent_uri?("entity://agent/" <> rest) do
            case String.split(rest, "/", parts: 2) do
              [_workspace, "cc_" <> _] -> true
              _ -> false
            end
          end
        end
        """)

      violations = Scan.scan_paths([path])

      assert [%Scan.Violation{category: :flavor_prefix_dependency} | _] =
               violations_for(violations, :flavor_prefix_dependency)
    end

    test "classifies dynamic flavor-prefix interpolation in agent URI names" do
      # The construction counterpart to the parsing rules — `"#{flavor}_#{name}"`
      # builds a flavor-prefixed agent URI name and must be flagged (codex review).
      path =
        fixture!("flavor_interp.ex", """
        defmodule Fixture.FlavorInterp do
          def build(flavor, name), do: Ezagent.URI.agent("ws", "\#{flavor}_\#{name}")
        end
        """)

      violations = Scan.scan_paths([path])

      assert [%Scan.Violation{category: :flavor_prefix_dependency} | _] =
               violations_for(violations, :flavor_prefix_dependency)
    end

    test "does not classify non-flavor interpolation as flavor-prefix dependency" do
      path =
        fixture!("plain_interp.ex", """
        defmodule Fixture.PlainInterp do
          def build(name, id), do: "\#{name}_\#{id}"
        end
        """)

      violations = Scan.scan_paths([path])

      assert [] = violations_for(violations, :flavor_prefix_dependency)
    end

    test "classifies flavor prefix adapter callbacks" do
      path =
        fixture!("agent_uri_prefix.ex", """
        defmodule Fixture.AgentUriPrefix do
          def agent_uri_prefix, do: "cc_"
        end
        """)

      violations = Scan.scan_paths([path])

      assert [%Scan.Violation{category: :flavor_prefix_dependency} | _] =
               violations_for(violations, :flavor_prefix_dependency)
    end

    test "classifies PR-C reorder-sensitive positional URI reads" do
      path =
        fixture!("positional_uri.ex", """
        defmodule Fixture.PositionalUri do
          def workspace_of(%URI{scheme: "session", path: "/" <> rest}) do
            String.split(rest, "/", parts: 2)
          end
        end
        """)

      violations = Scan.scan_paths([path])

      assert [%Scan.Violation{category: :positional_uri_read}] =
               violations_for(violations, :positional_uri_read)

      assert [%Scan.Violation{category: :tenant_derivation} | _] =
               violations_for(violations, :tenant_derivation)
    end

    test "does not classify thin wrappers that delegate to Ezagent.URI accessors/builders" do
      path =
        fixture!("thin_wrappers.ex", """
        defmodule Fixture.ThinWrappers do
          def workspace_of(uri), do: Ezagent.URI.workspace_of(uri)

          def worker_uri_for(session_uri, hash) do
            Ezagent.URI.worker(Ezagent.URI.workspace_name!(session_uri), "em_\#{hash}")
          end
        end
        """)

      violations = Scan.scan_paths([path])

      assert [] = violations_for(violations, :tenant_derivation)
    end

    test "does not classify external URL validation as an ezagent positional read" do
      path =
        fixture!("external_url.ex", """
        defmodule Fixture.ExternalUrl do
          def web?(%URI{scheme: "http", host: host, userinfo: nil}) when host != "", do: true
          def web?(%URI{scheme: "https", host: host, userinfo: nil}) when host != "", do: true

          def web?(_uri), do: false
        end
        """)

      assert [] =
               path
               |> then(&Scan.scan_paths([&1]))
               |> violations_for(:positional_uri_read)
    end

    test "does not classify provider refs or relative file paths as tenant derivation" do
      path =
        fixture!("relative_paths.ex", """
        defmodule Fixture.RelativePaths do
          def ref_segments(ref), do: String.split(ref, "/")
          def file_segments(path), do: String.split(path, "/")
        end
        """)

      assert [] =
               path
               |> then(&Scan.scan_paths([&1]))
               |> violations_for(:tenant_derivation)
    end

    test "still classifies ezagent URI splits when bindings are named path or ref" do
      path =
        fixture!("opaque_uri_aliases.ex", """
        defmodule Fixture.OpaqueUriAliases do
          def workspace(%URI{scheme: "resource", path: path}), do: String.split(path, "/")
          def workspace(%URI{scheme: "session", path: ref, userinfo: nil}), do: String.split(ref, "/")
          def workspace(%URI{} = uri) do
            path = uri.path
            String.split(path, "/")
          end
          def workspace(%URI{} = uri) do
            %{path: path} = uri
            String.split(path, "/")
          end
          def workspace(%URI{} = uri) do
            path = Map.fetch!(uri, :path)
            String.split(path, "/")
          end
          def workspace(%URI{} = uri) do
            {:ok, path} = Map.fetch(uri, :path)
            String.split(path, "/")
          end
        end
        """)

      violations = Scan.scan_paths([path])
      assert length(violations_for(violations, :positional_uri_read)) == 2
      assert length(violations_for(violations, :tenant_derivation)) == 6
    end

    test "classifies raw affected-scheme URI construction including interpolation" do
      path =
        fixture!("raw_uri.ex", """
        defmodule Fixture.RawUri do
          def agent_uri(workspace, name) do
            Ezagent.URI.new!("entity://agent/\#{workspace}/cc_\#{name}")
          end
        end
        """)

      violations = Scan.scan_paths([path])

      assert [%Scan.Violation{category: :raw_uri_construction}] =
               violations_for(violations, :raw_uri_construction)
    end

    test "does not classify documentation examples as raw URI construction" do
      path =
        fixture!("doc_uri_examples.ex", """
        defmodule Fixture.DocUriExamples do
          @moduledoc \"\"\"
          Examples:

              entity://team-alpha/agent/cc_demo
              workspace://team-alpha
          \"\"\"

          @doc \"\"\"
          Accepts `session://team-alpha/default/main`.
          \"\"\"
          def build(name) do
            Ezagent.URI.new!("entity://team-alpha/agent/\#{name}")
          end
        end
        """)

      violations = Scan.scan_paths([path])

      assert [%Scan.Violation{category: :raw_uri_construction}] =
               violations_for(violations, :raw_uri_construction)

      assert [] =
               violations
               |> Enum.filter(&(&1.snippet =~ "workspace://team-alpha"))
    end

    test "does not classify typedoc or shortdoc examples as raw URI construction" do
      path =
        fixture!("typedoc_uri_examples.ex", """
        defmodule Fixture.TypedocUriExamples do
          @shortdoc "Works with workspace://team-alpha"

          @typedoc \"\"\"
          Pattern examples:

              session://team-alpha/default/main
              entity://team-alpha/agent/opaque-name
          \"\"\"
          @type t :: :ok

          def build(name) do
            Ezagent.URI.new!("entity://team-alpha/agent/\#{name}")
          end
        end
        """)

      violations = Scan.scan_paths([path])

      assert [%Scan.Violation{category: :raw_uri_construction}] =
               violations_for(violations, :raw_uri_construction)

      refute Enum.any?(violations, &(&1.snippet =~ "workspace://team-alpha"))
      refute Enum.any?(violations, &(&1.snippet =~ "session://team-alpha/default/main"))
    end

    test "classifies orchestrator re-derivation calls" do
      path =
        fixture!("orchestrator.ex", """
        defmodule Fixture.Orchestrator do
          def build(session_uri, workspace_uri) do
            Ezagent.Entity.Session.derive_orchestrator_uri(session_uri, workspace_uri)
          end
        end
        """)

      violations = Scan.scan_paths([path])

      assert [%Scan.Violation{category: :orchestrator_derivation}] =
               violations_for(violations, :orchestrator_derivation)
    end

    test "classifies an unknown ezagent-like scheme as unknown_scheme_construction (T1-C)" do
      path =
        fixture!("unknown_scheme.ex", """
        defmodule Fixture.UnknownScheme do
          def build do
            raw = "config://default/socialware/autoservice"
            other = "foo://bar/baz"
            {raw, other}
          end
        end
        """)

      violations = Scan.scan_paths([path])
      unknown = violations_for(violations, :unknown_scheme_construction)

      assert Enum.any?(unknown, &(&1.snippet =~ "config://"))
      assert Enum.any?(unknown, &(&1.snippet =~ "foo://"))
    end

    test "does not classify registered external-URL schemes (T1-C allowlist)" do
      path =
        fixture!("external_urls.ex", """
        defmodule Fixture.ExternalUrls do
          def urls do
            [
              "postgresql://localhost:5432/db",
              "unix:///tmp/sock",
              "http://example.com",
              "https://open.feishu.cn/api",
              "ws://127.0.0.1/socket",
              "test://receiver/x",
              "cc-bridge://audit/synthetic"
            ]
          end
        end
        """)

      violations = Scan.scan_paths([path])

      assert violations_for(violations, :unknown_scheme_construction) == []
      assert violations_for(violations, :raw_uri_construction) == []
      assert violations_for(violations, :raw_cross_cutting_uri_construction) == []
    end

    test "current source tree has no URI-query scan violations" do
      violations = Scan.scan()
      counts = Scan.counts_by_category(violations)

      assert violations == []
      assert Map.get(counts, :flavor_prefix_dependency, 0) == 0
      assert Map.get(counts, :positional_uri_read, 0) == 0
    end
  end

  defp violations_for(violations, category) do
    Enum.filter(violations, &(&1.category == category))
  end

  defp fixture!(name, source) do
    dir =
      Path.join(System.tmp_dir!(), "ezagent-uri-query-scan-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    path = Path.join(dir, name)
    File.write!(path, source)
    path
  end
end
