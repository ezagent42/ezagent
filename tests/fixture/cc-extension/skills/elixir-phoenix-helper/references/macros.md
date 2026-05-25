# Elixir Macros

Macros are compile-time code generation. They look powerful, and they are — but they are also the single most abused feature of Elixir. **The default answer to "should I write a macro?" is no.** This file covers when the answer is yes, how to do it safely, and the anti-patterns to avoid.

## The default: write a function

Before reaching for `defmacro`, make sure the problem actually needs compile-time work:

| Situation | Use |
|---|---|
| Reusable behavior across many modules | **`use` with a protocol or behaviour**, not a macro that injects code |
| Configurable behavior | **Function with options** |
| Avoiding boilerplate | **Helper functions + composition** |
| DSL for domain logic | Almost always **plain functions**, occasionally a macro |
| Code that references functions the caller hasn't imported yet | **A macro — this is a legitimate case** |
| Code that depends on the *literal AST* of its arguments (not just the values) | **A macro** |
| Code that must run at compile time for performance or verification | **A macro** |

If you cannot articulate why a function will not work, a macro is the wrong tool. "Cleaner syntax" is rarely enough reason — macros pay a cost in debuggability, tooling support, and onboarding.

## Real reasons to write a macro

These are the situations where macros are the right answer — and the only ones worth designing around:

1. **Phoenix-style DSLs** that inspect unquoted AST, e.g. `Ecto.Query.from`'s `where` clause uses operators that only make sense at compile time.
2. **`use MyModule`** patterns that wire callers into a behaviour (`use GenServer`, `use Phoenix.LiveView`, `use Ecto.Schema`).
3. **Compile-time verification** — checking invariants at compile time that would be expensive or impossible to check at runtime (e.g. `Phoenix.VerifiedRoutes` validates `~p"..."` paths against the router at compile time).
4. **Code generation from schemas or specifications** where writing every function by hand is genuinely infeasible — e.g. protocol implementations, struct-per-row ORMs.
5. **Custom `sigil_X`** for domain-specific literals.

Notice what's *not* in this list: "making the syntax nicer", "saving a few keystrokes", "avoiding `if` statements".

## Basic `defmacro`

```elixir
defmodule MyApp.Log do
  defmacro log_call(func_call) do
    quote do
      before = System.monotonic_time(:microsecond)
      result = unquote(func_call)
      elapsed = System.monotonic_time(:microsecond) - before
      IO.puts("#{unquote(Macro.to_string(func_call))} took #{elapsed}μs")
      result
    end
  end
end

# Usage:
import MyApp.Log
log_call(expensive_operation(x, y))
```

Key points:

- **`quote do ... end`** produces the AST the macro expands to.
- **`unquote(expr)`** injects the evaluated value of `expr` (at macro-expansion time) into the quoted AST.
- **`Macro.to_string/1`** turns AST back into source code for display.

### Hygiene

Elixir macros are *hygienic* by default — variables introduced inside `quote` do not collide with variables in the calling scope. This is usually what you want:

```elixir
defmacro safe_double(x) do
  quote do
    temp = unquote(x)
    temp * 2
  end
end

# In the caller:
temp = "my variable"
result = safe_double(10)  # => 20
IO.puts(temp)  # still "my variable" — the macro's `temp` did not clobber it
```

If you *do* need to introduce a variable visible to the caller (rare, almost always a bad idea), use `var!/2`:

```elixir
defmacro bind_value(val) do
  quote do
    var!(result) = unquote(val)  # intentionally escapes hygiene
  end
end
```

**Rule:** if you are using `var!/2`, document loudly *why*, because the caller will be surprised by magical variables appearing in their scope.

## The `__using__/1` pattern

`use MyModule` is sugar for `require MyModule; MyModule.__using__(opts)`. The `__using__/1` macro typically injects a block into the caller — this is how Phoenix, Ecto, and GenServer wire callers into their framework.

```elixir
defmodule MyApp.Worker do
  @callback perform(args :: map()) :: :ok | {:error, term()}

  defmacro __using__(opts) do
    quote do
      @behaviour MyApp.Worker
      @queue unquote(Keyword.get(opts, :queue, :default))

      def queue, do: @queue

      # Default implementation — caller can override
      def perform(_args), do: :ok
      defoverridable perform: 1
    end
  end
end

defmodule MyApp.SendEmailWorker do
  use MyApp.Worker, queue: :mailers

  @impl true
  def perform(%{"user_id" => id}) do
    # ...
  end
end
```

Guidelines:

- **Minimize what `__using__/1` injects.** Every line injected is a line the caller now has to mentally carry. Prefer injecting `@behaviour` declarations and small glue over large code blocks.
- **Use `defoverridable`** for methods the caller should be able to customize.
- **Keep the `quote` block short** and call out to helper functions for complex logic.
- **Document what `use` does** — the caller has no other way to discover the injected code without reading the source.

## Testing macros

Macros expand at compile time, so you test the *expanded output*:

```elixir
defmodule MyApp.LogTest do
  use ExUnit.Case
  require MyApp.Log

  test "log_call expands to include elapsed time" do
    quoted = quote do
      MyApp.Log.log_call(some_fun())
    end

    expanded = Macro.expand_once(quoted, __ENV__)
    assert Macro.to_string(expanded) =~ "System.monotonic_time"
  end

  # Also test runtime behavior when the macro is invoked:
  test "log_call returns the wrapped value" do
    require MyApp.Log
    assert MyApp.Log.log_call(1 + 1) == 2
  end
end
```

Test both: the AST shape (so refactors don't silently change what gets injected) and the runtime behavior (so the final code does the right thing).

## Macro anti-patterns

### 1. Unnecessary macros

A macro that does what a function could do. The most common offender.

```elixir
# Anti-pattern — this is a macro for no reason
defmacro double(x) do
  quote do
    unquote(x) * 2
  end
end

# Just write the function
def double(x), do: x * 2
```

**Rule:** if the macro does not need the AST of its arguments (only the values), it should be a function. Test yourself: can you rewrite it without `quote`/`unquote`? If yes, it's a function.

### 2. Large code generation

Injecting hundreds of lines through `__using__/1`, making the caller's module balloon invisibly. Affects compile times, error messages (stack traces point to weird places), and tooling (IDE cannot show what functions the module has).

```elixir
# Anti-pattern — injects 20+ functions the caller didn't write
defmacro __using__(_opts) do
  quote do
    def fun1, do: # ...
    def fun2, do: # ...
    # ... 20 more
  end
end

# Better — caller explicitly imports or delegates
defmodule MyApp.Helpers do
  def fun1, do: # ...
  def fun2, do: # ...
end

# Caller:
defmodule MyModule do
  import MyApp.Helpers, only: [fun1: 0, fun2: 0]
end
```

**Rule:** if `__using__/1` injects more than ~5 functions or ~30 lines, it is probably doing too much.

### 3. `use` where `import` would do

`use X` is heavier than `import X`. Use `import` when you only need functions/macros brought into scope without other side effects.

```elixir
# Anti-pattern — defining __using__ just to call import
defmodule MyApp.StringHelpers do
  defmacro __using__(_opts) do
    quote do
      import MyApp.StringHelpers
    end
  end

  def titleize(str), do: # ...
end

# Caller: use MyApp.StringHelpers

# Better — skip the middleman
defmodule MyApp.StringHelpers do
  def titleize(str), do: # ...
end

# Caller: import MyApp.StringHelpers
```

### 4. Compile-time dependencies from macros

Every module a macro touches via `quote` becomes a **compile-time dependency** of every module that calls the macro. Touch `UserSchema` inside a `__using__/1`, and every module that `use`s the wrapper recompiles when `UserSchema` changes. This is how Elixir projects end up with "why does my whole app recompile on every change" problems.

```elixir
# Anti-pattern — every `use MyApp.Worker` gets a compile-time dep on Config
defmacro __using__(_opts) do
  quote do
    @config MyApp.Config.worker_config()  # compile-time call
  end
end

# Better — read the config at runtime, per-call
defmacro __using__(_opts) do
  quote do
    def config, do: MyApp.Config.worker_config()
  end
end
```

Inspect compile-time dependencies with `mix xref graph --label compile`. If the graph is dense, macros are usually the cause.

### 5. Injecting unexpected code

Macros that quietly add behavior the caller did not ask for — imports, `@before_compile` hooks, shadowed functions, variables in scope. Surprising the caller is the cardinal sin of macro design.

```elixir
# Anti-pattern — silently adds a `log` function that shadows anything
# the caller might have defined themselves
defmacro __using__(_opts) do
  quote do
    def log(msg), do: IO.puts("[#{__MODULE__}] #{msg}")  # silent shadowing
  end
end

# Better — let the caller decide whether to import it
defmodule MyApp.Logger do
  def log(module, msg), do: IO.puts("[#{module}] #{msg}")
end

# Caller: import MyApp.Logger (explicit)
```

### 6. Macros that behave differently based on source position

Using `__CALLER__` or `__ENV__` metadata to change behavior based on where the macro was called from. Makes the macro's behavior location-dependent, which is impossible to reason about without reading the macro's source.

Legitimate uses of `__CALLER__`: generating compile errors with useful line numbers, checking whether the caller has imported something. Illegitimate: branching the generated code based on `__CALLER__.module` so different callers get subtly different behavior.

### 7. Dynamic code generation from strings

`Code.eval_string/1` and `Code.string_to_quoted/1` at compile time, generating AST from string templates. Loses all syntax checking the compiler would otherwise give you; makes the generated code invisible to grep, IDEs, and the type system.

```elixir
# Anti-pattern
defmacro __using__(opts) do
  fields = Keyword.fetch!(opts, :fields)
  code = Enum.map(fields, fn f -> "def #{f}, do: @#{f}" end) |> Enum.join("\n")
  Code.string_to_quoted!(code)
end

# Better — build the AST directly
defmacro __using__(opts) do
  fields = Keyword.fetch!(opts, :fields)

  for field <- fields do
    quote do
      def unquote(field)(), do: unquote(Macro.var(:"@#{field}", __MODULE__))
    end
  end
end
```

The AST-direct version is grep-able (you can find `def unquote(field)`), syntax-checked by the compiler, and visible to tooling.

## When in doubt, reach for Plain Old Elixir

Most "I need a macro" moments dissolve into:

- A function that takes options.
- A behaviour with a default implementation via `defoverridable`.
- A protocol for polymorphism.
- A struct + pattern-matching functions.
- `import`-ing a helper module.

Macros earn their complexity only when these fail. For the ezagent/zchat/Socialware kind of work where you are modeling organizational primitives, the plain-Elixir toolkit (structs, behaviours, protocols, Contexts) goes very far. Reach for macros only when you have an actual DSL need that the language's built-ins cannot express.

## Reading existing macros

When reviewing code that already uses macros, ask:

1. **Could this be a function?** If yes, suggest the refactor.
2. **Does `__using__/1` inject more than ~5 functions?** If yes, suggest extracting the injected code into an explicitly-imported helper module.
3. **Does the macro reference other modules via `quote`?** Check `mix xref graph --label compile` — every caller gets a compile-time dep.
4. **Is there a `var!/2` without a loud comment explaining why?** Flag it.
5. **Is there `Code.eval_string` / `Code.string_to_quoted`?** Almost always convertible to direct AST construction.

If the macro passes all five checks, it is probably fine as-is.
