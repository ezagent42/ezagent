defmodule Ezagent.InterfaceValidatorTest do
  use ExUnit.Case, async: true
  alias Ezagent.InterfaceValidator

  defmodule ClosedEvidence do
    defstruct [:id, :status]
  end

  describe "primitives" do
    test ":string matches binary, fails on int" do
      assert :ok = InterfaceValidator.validate(%{x: "hi"}, %{x: :string})

      assert {:error, {:invalid_args, [{[:x], {:type_mismatch, _}}]}} =
               InterfaceValidator.validate(%{x: 1}, %{x: :string})
    end

    test ":integer matches int, fails on string" do
      assert :ok = InterfaceValidator.validate(%{n: 42}, %{n: :integer})

      assert {:error, {:invalid_args, _}} =
               InterfaceValidator.validate(%{n: "42"}, %{n: :integer})
    end

    test ":boolean / :atom / :map primitives" do
      assert :ok =
               InterfaceValidator.validate(%{b: true, a: :foo, m: %{}}, %{
                 b: :boolean,
                 a: :atom,
                 m: :map
               })
    end

    test ":uri accepts %URI{} struct, rejects bare string" do
      uri = URI.new!("entity://team-alpha/agent/test_cc-builder")
      assert :ok = InterfaceValidator.validate(%{u: uri}, %{u: :uri})

      assert {:error, {:invalid_args, [{[:u], {:type_mismatch, _}}]}} =
               InterfaceValidator.validate(%{u: "entity://team-alpha/agent/test_cc-builder"}, %{
                 u: :uri
               })
    end
  end

  describe "missing fields" do
    test "missing required field produces :missing violation" do
      assert {:error, {:invalid_args, [{[:x], :missing}]}} =
               InterfaceValidator.validate(%{}, %{x: :string})
    end

    test "missing optional field is OK" do
      assert :ok = InterfaceValidator.validate(%{}, %{x: {:option, :string}})
    end
  end

  describe "composites" do
    test "{:struct, Module} accepts only the exact declared struct keyset" do
      evidence = %ClosedEvidence{id: "evidence-1", status: :valid}
      secret = "interface-struct-secret-sentinel"

      assert :ok =
               InterfaceValidator.validate(%{evidence: evidence}, %{
                 evidence: {:struct, ClosedEvidence}
               })

      for forged <- [Map.put(evidence, :unsigned_extra, secret), Map.delete(evidence, :status)] do
        assert {:error, {:invalid_args, _violations}} =
                 result =
                 InterfaceValidator.validate(%{evidence: forged}, %{
                   evidence: {:struct, ClosedEvidence}
                 })

        refute inspect(result) =~ secret
      end
    end

    test "{:closed_map, schema} rejects extra keys without changing open-map compatibility" do
      value = %{name: "alice", extension: "kept-compatible"}

      assert :ok = InterfaceValidator.validate(value, %{name: :string})

      assert {:error, {:invalid_args, violations}} =
               InterfaceValidator.validate(value, {:closed_map, %{name: :string}})

      assert [{[], :unexpected_fields}] = violations
      refute inspect(violations) =~ "kept-compatible"
      assert :ok = InterfaceValidator.validate(%{name: "alice"}, {:closed_map, %{name: :string}})
    end

    test "{:list, ty} validates each element" do
      assert :ok =
               InterfaceValidator.validate(%{xs: [1, 2, 3]}, %{xs: {:list, :integer}})

      assert {:error, {:invalid_args, vs}} =
               InterfaceValidator.validate(%{xs: [1, "two", 3]}, %{xs: {:list, :integer}})

      assert [{[:xs, 1], {:type_mismatch, _}}] = vs
    end

    test "{:tuple, [tys]} validates by position" do
      assert :ok =
               InterfaceValidator.validate(%{pair: {1, "a"}}, %{
                 pair: {:tuple, [:integer, :string]}
               })

      assert {:error, {:invalid_args, _}} =
               InterfaceValidator.validate(%{pair: {1, 2}}, %{pair: {:tuple, [:integer, :string]}})
    end

    test "nested map shape" do
      schema = %{user: %{name: :string, age: :integer}}
      assert :ok = InterfaceValidator.validate(%{user: %{name: "x", age: 30}}, schema)

      assert {:error, {:invalid_args, vs}} =
               InterfaceValidator.validate(%{user: %{name: "x", age: "thirty"}}, schema)

      assert [{[:user, :age], {:type_mismatch, _}}] = vs
    end

    test "{:option, ty} accepts nil and the inner type" do
      assert :ok = InterfaceValidator.validate(%{x: nil}, %{x: {:option, :string}})
      assert :ok = InterfaceValidator.validate(%{x: "hi"}, %{x: {:option, :string}})
    end
  end

  test "collects all violations, not just the first" do
    assert {:error, {:invalid_args, vs}} =
             InterfaceValidator.validate(
               %{a: 1, b: "wrong"},
               %{a: :string, b: :integer}
             )

    # Two violations: a is not string, b is not integer.
    assert length(vs) == 2
  end

  describe "validate_action/1 — @interface action-map shape (V1 UI SPEC §0)" do
    test "action map with no :description key is valid (optional)" do
      assert :ok =
               InterfaceValidator.validate_action(%{
                 args: %{msg: :string},
                 returns: %{echo: :string},
                 modes: [:call]
               })
    end

    test "action map with a binary :description is valid" do
      assert :ok =
               InterfaceValidator.validate_action(%{
                 description: "Echo a string back to the caller",
                 args: %{msg: :string},
                 returns: %{echo: :string},
                 modes: [:call]
               })
    end

    test "non-binary :description produces an :invalid_interface violation" do
      assert {:error, {:invalid_interface, [{[:description], {:type_mismatch, _}}]}} =
               InterfaceValidator.validate_action(%{
                 description: :not_a_string,
                 args: %{},
                 returns: %{},
                 modes: [:call]
               })
    end
  end
end
