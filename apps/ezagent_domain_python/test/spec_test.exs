defmodule Ezagent.Domain.Python.SpecTest do
  use ExUnit.Case, async: true

  alias Ezagent.Domain.Python.Spec

  describe "validate/1" do
    test "accepts a minimal :uv_script spec" do
      spec = %Spec{
        handle: URI.parse("system://python/x"),
        command: :uv_script,
        script_path: "/tmp/foo.py",
        cwd: System.tmp_dir!()
      }

      assert :ok = Spec.validate(spec)
    end

    test "rejects bad cwd" do
      spec = %Spec{
        handle: URI.parse("system://python/x"),
        command: :uv_script,
        script_path: "/tmp/foo.py",
        cwd: "/no/such/dir/here-#{System.unique_integer([:positive])}"
      }

      assert {:error, :bad_cwd} = Spec.validate(spec)
    end

    test ":uv_script without script_path is rejected" do
      spec = %Spec{
        handle: URI.parse("system://python/x"),
        command: :uv_script,
        cwd: System.tmp_dir!()
      }

      assert {:error, {:missing, :script_path}} = Spec.validate(spec)
    end

    test ":uv_project without project_dir is rejected" do
      spec = %Spec{
        handle: URI.parse("system://python/x"),
        command: :uv_project,
        entry_module: "mymod",
        cwd: System.tmp_dir!()
      }

      assert {:error, {:missing, :project_dir}} = Spec.validate(spec)
    end

    test ":uv_project without entry_module is rejected" do
      spec = %Spec{
        handle: URI.parse("system://python/x"),
        command: :uv_project,
        project_dir: System.tmp_dir!(),
        cwd: System.tmp_dir!()
      }

      assert {:error, {:missing, :entry_module}} = Spec.validate(spec)
    end

    test "explicit argv list passes" do
      spec = %Spec{
        handle: URI.parse("system://python/x"),
        command: ["/usr/bin/false"],
        cwd: System.tmp_dir!()
      }

      assert :ok = Spec.validate(spec)
    end

    test "bad command shape is rejected" do
      spec = %Spec{
        handle: URI.parse("system://python/x"),
        command: :not_a_known_atom,
        cwd: System.tmp_dir!()
      }

      assert {:error, :bad_command} = Spec.validate(spec)
    end
  end

  describe "to_argv/1" do
    test "explicit argv passes through verbatim" do
      spec = %Spec{
        handle: URI.parse("system://python/x"),
        command: ["/usr/bin/false", "--flag", "value"],
        cwd: System.tmp_dir!()
      }

      assert {:ok, ["/usr/bin/false", "--flag", "value"]} = Spec.to_argv(spec)
    end

    test ":uv_script returns {:error, :uv_not_found} when PATH lacks uv" do
      original_path = System.get_env("PATH")
      System.put_env("PATH", "/nonexistent-#{System.unique_integer([:positive])}")

      try do
        spec = %Spec{
          handle: URI.parse("system://python/x"),
          command: :uv_script,
          script_path: "/tmp/foo.py",
          cwd: System.tmp_dir!()
        }

        assert {:error, :uv_not_found} = Spec.to_argv(spec)
      after
        if original_path, do: System.put_env("PATH", original_path), else: System.delete_env("PATH")
      end
    end

    test ":uv_script builds [uv, run, --script, path] when uv is available" do
      # Only run if uv is on PATH locally.
      uv = System.find_executable("uv")

      if uv do
        spec = %Spec{
          handle: URI.parse("system://python/x"),
          command: :uv_script,
          script_path: "/tmp/foo.py",
          cwd: System.tmp_dir!()
        }

        assert {:ok, [^uv, "run", "--script", "/tmp/foo.py"]} = Spec.to_argv(spec)
      end
    end

    test ":uv_project builds the directory + python -m form" do
      uv = System.find_executable("uv")

      if uv do
        spec = %Spec{
          handle: URI.parse("system://python/x"),
          command: :uv_project,
          project_dir: System.tmp_dir!(),
          entry_module: "my.mod",
          cwd: System.tmp_dir!()
        }

        assert {:ok, [^uv, "run", "--directory", _dir, "--", "python", "-m", "my.mod"]} =
                 Spec.to_argv(spec)
      end
    end
  end
end
