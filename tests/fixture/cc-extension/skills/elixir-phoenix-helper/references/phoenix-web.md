# Phoenix Web (Controllers, Plugs, Router, Scopes, LiveView, Components, Layouts)

**Default target: Phoenix 1.8+ and LiveView 1.1+.** If the project is on an older version, query Context7 for the specific version's docs and adapt.

## The mental model

Phoenix is a thin web adapter over your domain code:

```
HTTP request
  ↓  Endpoint (plug pipeline: logger, parsers, session, router)
  ↓  Router (match path → pipeline → scope → controller/LiveView)
  ↓  Plug pipeline (auth, CSRF, scope resolution)
  ↓  Controller action  OR  LiveView mount+handle_*
  ↓  Context call — ALWAYS takes `scope` as first arg for user-owned data:
     MyApp.Blog.list_posts(scope)  ← domain logic lives HERE
  ↓  Function components (HEEx) — <Layouts.app> wraps page content
  ↓  HTTP response
```

Controllers, LiveViews, and components are **thin**. Domain logic goes in Contexts. **Since Phoenix 1.8, every context function that reads or writes user-owned data takes `scope` as its first argument.** This is not optional; it is how Phoenix makes authorization structural rather than remembered.

## Scopes (Phoenix 1.8+, the most important change)

A Scope is a plain struct in your app that holds the context for the current request or session: the current user, their organization, an API key's permissions, whatever your app needs to authorize and filter data. Phoenix 1.8 made Scopes a first-class concept — generators thread them through, routers integrate with them, and the entire context + PubSub pattern assumes them.

### The scope struct

`mix phx.gen.auth` generates this (or augment it yourself):

```elixir
defmodule MyApp.Accounts.Scope do
  @moduledoc """
  Holds information about the current request: the user, their org,
  permissions, and anything else downstream code needs for authorization
  and data filtering.
  """

  alias MyApp.Accounts.User

  @type t :: %__MODULE__{
          user: User.t() | nil,
          organization: MyApp.Orgs.Organization.t() | nil
        }

  defstruct [:user, :organization]

  @doc "Build a scope from a just-authenticated user."
  def for_user(%User{} = user), do: %__MODULE__{user: user}
  def for_user(nil), do: nil

  @doc "Augment an existing scope with organization context."
  def put_organization(%__MODULE__{} = scope, org), do: %{scope | organization: org}
end
```

Keep the struct **yours**. It is not a Phoenix type — it is a plain struct in your Accounts (or whatever) context. You can add fields (`api_key`, `impersonator`, `request_id`, `ip_address`) as your app grows.

### Config: declaring the default scope

```elixir
# config/config.exs
config :my_app, :scopes,
  user: [
    default: true,
    module: MyApp.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id]
  ]
```

When set, generators (`phx.gen.live`, `phx.gen.html`, `phx.gen.json`) produce scope-aware code by default.

### Context functions take `scope` first

Every context function that reads or writes user-owned data:

```elixir
defmodule MyApp.Blog do
  import Ecto.Query
  alias MyApp.{Repo, Accounts.Scope, Blog.Post}

  @spec list_posts(Scope.t()) :: [Post.t()]
  def list_posts(%Scope{} = scope) do
    Repo.all(from p in Post, where: p.user_id == ^scope.user.id, order_by: [desc: p.inserted_at])
  end

  @spec get_post!(Scope.t(), integer()) :: Post.t()
  def get_post!(%Scope{} = scope, id) do
    Repo.get_by!(Post, id: id, user_id: scope.user.id)
  end

  @spec create_post(Scope.t(), map()) :: {:ok, Post.t()} | {:error, Ecto.Changeset.t()}
  def create_post(%Scope{} = scope, attrs) do
    %Post{user_id: scope.user.id}
    |> Post.changeset(attrs)
    |> Repo.insert()
    |> broadcast(scope, :created)
  end

  @spec subscribe_posts(Scope.t()) :: :ok | {:error, term()}
  def subscribe_posts(%Scope{} = scope) do
    Phoenix.PubSub.subscribe(MyApp.PubSub, topic(scope))
  end

  defp broadcast({:ok, post} = result, scope, event) do
    Phoenix.PubSub.broadcast(MyApp.PubSub, topic(scope), {event, post})
    result
  end
  defp broadcast({:error, _} = result, _scope, _event), do: result

  defp topic(%Scope{user: %{id: uid}}), do: "user:#{uid}:posts"
end
```

Notice three things:

1. **The first argument is always `scope`**, pattern-matched as `%Scope{}` so a bare `nil` or map fails fast.
2. **Scope drives the PubSub topic** via a private `topic/1` helper — no string concatenation at call sites, no cross-scope leakage.
3. **Broadcasting happens inside the context** on successful writes, so callers do not need to remember to broadcast.

### Augmenting scopes (multi-tenancy, admin impersonation)

When you need more context than just the user (e.g. the user's current organization), extend the struct and thread it. For organization-scoped data, add an `:organization` field and change the filters:

```elixir
def list_posts(%Scope{user: _user, organization: %{id: org_id}}) do
  Repo.all(from p in Post, where: p.organization_id == ^org_id)
end
```

Pattern matching in the function head enforces "this function requires an org-scoped request" — a user-only scope will not match and will raise `FunctionClauseError`.

## Router & `live_session`

Phoenix 1.8 Router still uses pipelines and scopes, plus `live_session` for grouping LiveViews that share mount hooks and can navigate between each other without full remount.

```elixir
defmodule MyAppWeb.Router do
  use MyAppWeb, :router

  import MyAppWeb.UserAuth  # generated by phx.gen.auth, provides the mount hooks

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MyAppWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user  # sets conn.assigns.current_scope
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Public pages (no auth required)
  scope "/", MyAppWeb do
    pipe_through :browser

    live_session :public, on_mount: [{MyAppWeb.UserAuth, :mount_current_scope}] do
      live "/", PageLive.Home
    end
  end

  # Authenticated pages
  scope "/", MyAppWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{MyAppWeb.UserAuth, :ensure_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/posts", PostLive.Index, :index
      live "/posts/new", PostLive.Form, :new
      live "/posts/:id", PostLive.Show, :show
      live "/posts/:id/edit", PostLive.Form, :edit
    end
  end

  scope "/api", MyAppWeb.API do
    pipe_through :api
    resources "/posts", PostController, only: [:index, :show, :create]
  end
end
```

- **`live_session` matters.** LiveViews inside the same `live_session` can `push_navigate/2` between each other without remounting the socket. Crossing into a different `live_session` (or out of any) forces a remount.
- **`on_mount: [{MyAppWeb.UserAuth, :ensure_authenticated}]`** runs before every LiveView in the session — checks auth, redirects if absent, puts `current_scope` in assigns.
- **`fetch_current_scope_for_user`** (plug, also from `phx.gen.auth`) puts `conn.assigns.current_scope` for controller actions.
- **Verified routes** (`~p"/posts/#{post}"`) are compile-time checked. Use them everywhere — never raw strings.

## Controllers

Use controllers for JSON APIs, file downloads, webhooks, OAuth callbacks — anything fundamentally request/response. For interactive UIs, reach for LiveView instead.

```elixir
defmodule MyAppWeb.API.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog

  action_fallback MyAppWeb.FallbackController

  def index(conn, params) do
    posts = Blog.list_posts(conn.assigns.current_scope, params)
    render(conn, :index, posts: posts)
  end

  def create(conn, %{"post" => attrs}) do
    with {:ok, post} <- Blog.create_post(conn.assigns.current_scope, attrs) do
      conn
      |> put_status(:created)
      |> render(:show, post: post)
    end
  end
end
```

- **Every context call takes `conn.assigns.current_scope`**. If it does not, you are leaking data across users.
- **`action_fallback`** centralizes `{:error, _}` handling. Define a `FallbackController` that pattern-matches on `{:error, %Ecto.Changeset{}}`, `{:error, :not_found}`, `{:error, :unauthorized}`, etc.
- **Actions are thin.** If an action grows past ~15 lines, it is hoarding logic that belongs in the context.

### JSON rendering (Phoenix 1.7+ style)

```elixir
defmodule MyAppWeb.API.PostJSON do
  alias MyApp.Blog.Post

  def index(%{posts: posts}), do: %{data: for(p <- posts, do: data(p))}
  def show(%{post: post}),    do: %{data: data(post)}

  defp data(%Post{} = p) do
    %{id: p.id, title: p.title, body: p.body, inserted_at: p.inserted_at}
  end
end
```

## Plugs

A plug is `init/1` + `call/2` (module plug) or just a function (`plug :my_func`). Use plugs for cross-cutting concerns: auth, rate limiting, request ID injection, tenant resolution.

The `phx.gen.auth` generator creates `MyAppWeb.UserAuth` with the plugs and hooks you need (`fetch_current_scope_for_user`, `require_authenticated_user`, `require_sudo_mode`, etc.). Use those rather than rolling your own — they handle the session, CSRF, and remember-me cookie correctly.

For new plugs:

```elixir
defmodule MyAppWeb.Plugs.RequireOrg do
  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(%Plug.Conn{assigns: %{current_scope: %{organization: nil}}} = conn, _opts) do
    conn
    |> put_flash(:error, "Please select an organization")
    |> redirect(to: ~p"/orgs")
    |> halt()
  end

  def call(conn, _opts), do: conn
end
```

**`halt/1` is essential** when redirecting from a plug — without it, later plugs still run.

## Contexts — the domain layer

A Context is a module exposing a cohesive set of operations on a domain. It is the boundary between web and the database.

Rules:

- **Contexts own Repo access.** Controllers and LiveViews never `Repo.all/get/insert` directly.
- **Every public function takes `scope` as its first argument** when it reads or writes user-owned data. Pure utility functions (e.g. a helper that validates a slug format) do not need a scope.
- **Return `{:ok, _} / {:error, _}`** for fallible operations; `Repo.get!/2` is fine for obviously-should-exist fetches.
- **One context per bounded sub-domain.** `Accounts`, `Billing`, `Messaging`, `Analytics`. Not one context per schema.
- **Schemas live inside their context** (`MyApp.Blog.Post`, not `MyApp.Post`).
- **Broadcasting happens inside the context** on successful writes — callers should not have to remember to broadcast.

## LiveView

LiveView is the default for interactive UIs in Phoenix 1.8+. You write Elixir on the server, state changes drive efficient diffs to the client over a WebSocket.

### Lifecycle

```
mount/3         ← runs twice: once over HTTP (for SSR), once over WebSocket (for interactivity)
handle_params/3 ← after mount, and whenever URL params change (live navigation)
render/1        ← returns HEEx based on assigns
handle_event/3  ← user-triggered events from the client (phx-click, phx-submit, etc.)
handle_info/2   ← async messages (PubSub, send_after, Task results)
terminate/2     ← optional cleanup
```

### Canonical LiveView module (scope-aware, Phoenix 1.8)

```elixir
defmodule MyAppWeb.PostLive.Index do
  use MyAppWeb, :live_view

  alias MyApp.Blog

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if connected?(socket), do: Blog.subscribe_posts(scope)

    {:ok,
     socket
     |> assign(:page_title, "Posts")
     |> stream(:posts, Blog.list_posts(scope))}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope
    post = Blog.get_post!(scope, id)
    {:ok, _} = Blog.delete_post(scope, post)
    {:noreply, stream_delete(socket, :posts, post)}
  end

  @impl true
  def handle_info({event, %Blog.Post{} = post}, socket) when event in [:created, :updated] do
    {:noreply, stream_insert(socket, :posts, post)}
  end

  def handle_info({:deleted, %Blog.Post{} = post}, socket) do
    {:noreply, stream_delete(socket, :posts, post)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        Listing Posts
        <:actions>
          <.link navigate={~p"/posts/new"} class="btn btn-primary">New post</.link>
        </:actions>
      </.header>

      <div id="posts" phx-update="stream">
        <div :for={{id, post} <- @streams.posts} id={id} class="card">
          <.link navigate={~p"/posts/#{post}"}>{post.title}</.link>
          <button phx-click="delete" phx-value-id={post.id}>Delete</button>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
```

What's new vs Phoenix 1.7:

- **`socket.assigns.current_scope`** is set by the `on_mount` hook from `phx.gen.auth`; reach for it instead of `current_user`.
- **Every `Blog.*` call takes `scope` first.** The compiler will not catch missing scopes — you have to write them.
- **`<Layouts.app>`** is a function component call inside `render/1` (new pattern; see below).

### `connected?/1` in `mount/3`

`mount/3` runs twice — once for the initial HTTP render (SSR) and once over the WebSocket. Anything expensive or subscription-based should be gated:

```elixir
if connected?(socket) do
  Blog.subscribe_posts(socket.assigns.current_scope)
  :timer.send_interval(5_000, :refresh)
end
```

### Streams (LiveView 1.0+) — for collections

Never put a list of items directly in assigns if the list can grow. Use `stream/3`:

```elixir
socket = stream(socket, :posts, Blog.list_posts(scope))
# Later:
socket = stream_insert(socket, :posts, new_post)
socket = stream_delete(socket, :posts, old_post)
# Full replacement (e.g. after filter change):
socket = stream(socket, :posts, Blog.list_posts(scope, filters), reset: true)
```

Streams keep item data client-side, so the server does not hold it — memory stays bounded. Template uses `phx-update="stream"` and iterates over `@streams.posts`.

**Use streams for any collection that grows, gets paginated, or could plausibly be >50 items.** Chat logs, notifications, activity feeds, search results — all streams.

### Function components (`Phoenix.Component`)

Function components are reusable HEEx snippets. Prefer them over LiveComponents unless you need server-side state.

```elixir
defmodule MyAppWeb.CoreComponents do
  use Phoenix.Component

  attr :rest, :global
  slot :inner_block, required: true

  def header(assigns) do
    ~H"""
    <header class="flex items-center justify-between mb-6" {@rest}>
      <h1 class="text-2xl font-semibold">
        {render_slot(@inner_block)}
      </h1>
    </header>
    """
  end
end
```

Use them via `<.header>...</.header>` in HEEx. `attr` declarations give compile-time checking of passed attributes.

Phoenix 1.8 `core_components.ex` is deliberately lighter than 1.7 — just the essentials. Build app-specific components on top.

### `LiveComponent` — only when you need isolated state

A `LiveComponent` has its own state, its own `handle_event/3`, and renders inside a parent LiveView. Use it when:

- The component has non-trivial internal state (open/closed, selection, form).
- You want targeted updates (`send_update/2`) without re-rendering the whole parent.

Do not reach for `LiveComponent` by default — it adds lifecycle complexity. A function component with attrs is almost always simpler.

### `push_navigate` vs `push_patch` vs `redirect`

- **`push_navigate(to: ~p"/other")`**: full LiveView navigation — remounts (except within the same `live_session`).
- **`push_patch(to: ~p"/same?tab=settings")`**: stay in the same LiveView, trigger `handle_params/3`. Use for tab switches, filter changes.
- **`redirect(to: ~p"/login")`**: full HTTP redirect — drops the socket. Use for auth or external links.

### Uploads

```elixir
def mount(_params, _session, socket) do
  {:ok, allow_upload(socket, :avatar, accept: ~w(.jpg .jpeg .png), max_entries: 1)}
end

def handle_event("save", _params, socket) do
  scope = socket.assigns.current_scope

  [url] =
    consume_uploaded_entries(socket, :avatar, fn %{path: path}, _entry ->
      dest = Path.join("priv/static/uploads", "#{scope.user.id}_#{Path.basename(path)}")
      File.cp!(path, dest)
      {:ok, "/uploads/#{Path.basename(dest)}"}
    end)

  {:noreply, assign(socket, avatar_url: url)}
end
```

The `:external` option in `allow_upload` lets you upload directly from the browser to S3 or R2 — use it for anything non-trivial to avoid proxying bytes through Phoenix.

## Layouts — the Phoenix 1.8 single-layout pattern

Phoenix 1.8 simplified layouts. The old "root layout + app layout nested via `use Phoenix.LiveView, layout: ...`" pattern is gone. Now:

- **`root.html.heex`** is still the static root wrapper (`<html>`, `<head>`, body shell, flash container). It is set once in the endpoint pipeline (`plug :put_root_layout`).
- **`<Layouts.app>`** is a **function component** that each LiveView / controller template calls explicitly inside its render.

This makes multi-layout apps trivial: need an admin layout? Define `<Layouts.admin>`. Need a marketing layout? `<Layouts.marketing>`. No special config — just a function component per layout variant.

### The `Layouts` module

```elixir
defmodule MyAppWeb.Layouts do
  use MyAppWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true
  attr :current_scope, :any, default: nil
  slot :inner_block, required: true
  slot :breadcrumb, required: false

  def app(assigns) do
    ~H"""
    <header class="navbar bg-base-100">
      <div class="flex-1">
        <.link navigate={~p"/"} class="btn btn-ghost text-xl">MyApp</.link>
      </div>
      <div :if={@current_scope}>
        <.link navigate={~p"/users/settings"}>{@current_scope.user.email}</.link>
      </div>
    </header>

    <main class="px-4 py-8">
      <div :if={@breadcrumb != []} class="breadcrumbs text-sm mb-4">
        <ul>
          <li :for={item <- @breadcrumb}>{render_slot(item)}</li>
        </ul>
      </div>
      <div class="mx-auto max-w-4xl">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end
end
```

### Using it from a LiveView

```elixir
def render(assigns) do
  ~H"""
  <Layouts.app flash={@flash} current_scope={@current_scope}>
    <:breadcrumb>
      <.link navigate={~p"/posts"}>All Posts</.link>
    </:breadcrumb>
    <:breadcrumb>
      <.link navigate={~p"/posts/#{@post}"}>{@post.title}</.link>
    </:breadcrumb>

    <.header>
      Post: {@post.title}
    </.header>

    <article>{@post.body}</article>
  </Layouts.app>
  """
end
```

**Always pass `flash={@flash}`**. Forgetting it means flash messages silently do not appear. The `current_scope` assign is conventional but optional; pass what your layout actually reads.

## daisyUI + Tailwind v4 (Phoenix 1.8 default)

New Phoenix 1.8 apps ship with **Tailwind v4 + daisyUI** for component classes (`btn btn-primary`, `navbar`, `card`, `breadcrumbs`, etc.) and a **dark mode toggle** in `core_components.ex` out of the box.

- **daisyUI classes** can be used alongside any Tailwind utility — no lock-in.
- **Theming** is configured in `assets/css/app.css` via the daisyUI `@plugin` directive. Change the theme without touching markup.
- **Removable**: it is just a Tailwind plugin, so `pnpm remove` (or `npm uninstall`) takes it out cleanly if you do not want it.

If the project is Phoenix 1.7 or earlier, do not introduce daisyUI unless the user asks — stick to plain Tailwind to match the existing codebase.

## Pitfalls in Phoenix web

1. **Context functions without `scope` as first arg** — data leakage across users/tenants. This is the #1 mistake migrating from Phoenix 1.7 to 1.8.
2. **Business logic in `handle_event/3`** — move to a context function.
3. **Business logic in `render/1`** — compute in `handle_event/3` or `handle_params/3`, assign, then read in render.
4. **Skipping `connected?(socket)` guard on expensive mount work** — doubles the cost of SSR.
5. **Putting a huge list in assigns instead of using a stream** — memory grows per connection.
6. **Raw path strings instead of `~p"..."` verified routes** — compile-time routing check lost.
7. **Forgetting `halt(conn)` in a plug after redirect** — later plugs and actions still run.
8. **One giant `:browser` pipeline for everything** — split into `:browser` + `:require_authenticated_user` + `:admin`.
9. **`Repo.*` calls inside a LiveView or controller** — goes through a context.
10. **`LiveComponent` when a function component would do** — adds lifecycle complexity with no gain.
11. **Nested layout pattern from Phoenix 1.7** (`use Phoenix.LiveView, layout: {MyAppWeb.Layouts, :app}`) — use the explicit `<Layouts.app>` function component call instead.
12. **Forgetting `flash={@flash}` in `<Layouts.app>` call** — flash messages silently disappear.
13. **Hard-coded PubSub topics instead of scope-derived** — see [realtime.md](realtime.md).
14. **Writing `current_user` when the codebase uses `current_scope`** (or vice versa) — check what the project actually assigns; they are not interchangeable.
