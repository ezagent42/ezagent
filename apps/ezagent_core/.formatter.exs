[
  import_deps: [:ecto, :ecto_sql],
  subdirectories: ["priv/*/migrations"],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  locals_without_parens: [
    # Ezagent DSL macros — authored paren-free by design. Without
    # registering them here the formatter rewrites `action :foo, ...`
    # → `action(:foo, ...)`, churning every Behavior/Kind/Lifecycle
    # module. Defined in: Ezagent.Behavior (action), Ezagent.Kind
    # (attach), Ezagent.Lifecycle (reads_siblings),
    # Ezagent.EventSubscriber (subscribe).
    action: 2,
    action: 3,
    attach: 1,
    attach: 2,
    reads_siblings: 1,
    subscribe: 1
  ],
  inputs: ["*.{heex,ex,exs}", "{config,lib,test}/**/*.{heex,ex,exs}", "priv/*/seeds.exs"]
]
