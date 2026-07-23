defmodule Ezagent.ActionSet.UserCredentials do
  @moduledoc """
  User-credential Behavior — operator-facing password mutation on the
  `users` Postgres table.

  ## Why a separate Behavior, not on `Identity`

  Per `docs/futures/todo.md` HIGH-2: password mutation cannot live on
  `Behavior.Identity` because the cap shape would conflate
  self-mutation rights with admin password reset — granting a user
  `(:user, Identity, :set_password)` to let them rotate their OWN
  password would simultaneously grant them admin's password-rotation
  authority on every OTHER user (Identity's cap shape is class-wide).

  A separate Behavior carves out `:set_password` so:

  - A user can hold `(:user, UserCredentials, :set_password)` against
    THEIR OWN URI (instance = their entity URI) to self-rotate.
  - Admin holds `(:user, UserCredentials, :set_password, :any)` to
    reset any user's password.
  - The cap-check at step 5.5 + step 5.6 (cross-workspace iso)
    enforces both shapes structurally.

  ## Actions

  - `:set_password` — args `%{password: String.t()}` →
    `%{user_uri: String.t(), password_set: true}`.
    Body wraps `Ezagent.Users.set_password/2` — the same call the
    legacy `mix ezagent.user.set_password` task makes — but routes
    through dispatch so step 5.5 cap-check, step 5.6 cross-workspace
    iso, and audit telemetry all apply.

  ## Slice

      %{set_password_count: integer()}

  Per the existing Routing / Feishu UserBinding pattern, the slice is
  an incidental counter — the durable table is owned by
  `Ezagent.Users` (the Ecto schema). The slice is not persisted; on
  Kind restart the count resets but the password hash survives.

  ## Cap shape (PR-CC-2-v2 contract)

  One per-action cap entry — `Capability.cap(:user, __MODULE__,
  :set_password)`. Kind axis is `:user` because the Behavior is
  registered on the User Kind. The default `workspace_scoped? = true`
  is correct here — a user URI carries its workspace structurally,
  and admin's bootstrap cap is `:any`-workspace which bypasses iso
  at step 5.6.

  ## Auto-derived CLI

      mix ezagent user set_password \\
          --user entity://user/<workspace>/<name> \\
          --password <new-pw>

  The legacy `mix ezagent.user.set_password` task is retained pending
  operator migration with a deprecation notice (PR #355 muscle-memory
  pattern).

  ## P2-b migration (2026-05-28)

  Migrated to the new `use Ezagent.ActionSet` action/handler contract
  per SPEC `docs/superpowers/specs/2026-05-28-router-behavior-kind-architecture.md`
  §4 + §6.2. The legacy `invoke/4` shim is replaced by
  `handle_set_password/2` returning effects. Slice machinery
  (`state_slice/0`, `init_slice/1`, `data_owner/1`) is preserved
  per §6.2 step 9 — the Kind.Server still calls these directly.
  Dispatch goes through `Ezagent.Kind.Runtime` post-#453+#454
  (Phase 1.5+1.5b — new-contract detection via `__behavior__?/0`).

  ## Phase B migration (2026-05-29) — `use Ezagent.Lifecycle`

  Converted to the Lifecycle developer API per SPEC
  `docs/superpowers/specs/2026-05-29-lifecycle-hooks-design.md` §5.
  STATE-ONLY: the slice is the incidental `set_password_count` counter
  (the durable password hash is owned by the `users` table via
  `Ezagent.Users`); no transients. `init_slice/1` → `create/1`;
  `activate/2` is the macro no-op (omitted). Auto-derived `state_slice`
  is `:user_credentials` (matches the old explicit one). Handler body
  byte-identical. `required_caps/0` + `data_owner/1` pass through.
  """

  use Ezagent.Lifecycle

  action(:set_password,
    args: %{password: :string},
    returns: %{user_uri: :string, password_set: :boolean},
    caps: [{:set_password, kind: :user}],
    description:
      "Set or rotate the User's password. Hashed via bcrypt before " <>
        "insert. The target user is the dispatch target's URI " <>
        "(`ctx.self_uri`); CLI passes it via `--user <entity-uri>`.",
    data_owner: :self,
    modes: [:call]
  )

  # =================================================================
  # Explicit `required_caps/0` — the new `caps:` macro grammar
  # accepts `kind: :user` per SPEC §4.3 form 2, but the Phase 1.5
  # macro's auto-derived `required_caps/0` hardcodes the kind axis to
  # `:any` (see `Ezagent.ActionSet.build_required_cap_ast/3`). Keeping
  # an explicit `def required_caps` overrides the macro derivation
  # (see `maybe_inject_legacy_callbacks` — it skips injection when
  # the callback is already defined) and preserves the historical
  # `kind: :user` cap shape until the macro grows full SPEC §4.3
  # form-2 support.
  # =================================================================
  def required_caps do
    %{
      set_password: Ezagent.Capability.cap(:user, __MODULE__, :set_password)
    }
  end

  # =================================================================
  # Lifecycle state — `create/1` builds the PERSISTENT counter once
  # (Phase B; was `init_slice/1`). No transients → `activate/2` is the
  # macro no-op. `state_slice` auto-derives to `:user_credentials`.
  # =================================================================

  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{set_password_count: 0}}

  # PR-OWN-4 data_owner pattern: the user (the Kind instance) owns its
  # credentials. Concrete user URIs map to themselves (self-owned;
  # the user holds the instance-scoped cap on their own URI for
  # self-rotation); `:any` matches `:any`; everything else has no
  # owner (no default grant). Admin's cross-user reset is via the
  # bootstrap `:any`-instance cap which short-circuits at step 5.5.
  def data_owner(%URI{} = entity_uri), do: entity_uri
  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner

  # =================================================================
  # New-contract action handler (§6.2 — replaces invoke/4)
  # =================================================================

  def handle_set_password(%{password: password}, ctx)
      when is_binary(password) and password != "" do
    with {:ok, user_uri} <- target_user_uri(ctx),
         {:ok, _decoded} <- Ezagent.Users.set_password(user_uri, password) do
      cur = ctx[:read].(:set_password_count, 0)

      {:ok, %{user_uri: Ezagent.URI.stable_key(user_uri), password_set: true},
       [
         {:set, :set_password_count, cur + 1},
         {:emit, :password_set,
          %{user_uri: Ezagent.URI.stable_key(user_uri), at: DateTime.utc_now()}}
       ]}
    end
  end

  def handle_set_password(args, _ctx) do
    {:error, {:bad_args, "set_password requires {password: non-empty String}", args}}
  end

  # =================================================================
  # Helpers
  # =================================================================

  # The User Kind's `ctx.self_uri` is the user URI we're operating on.
  # Test scenarios that build ctx manually may pass it directly.
  defp target_user_uri(ctx) do
    case Map.get(ctx, :self_uri) do
      %URI{scheme: "entity"} = uri ->
        if Ezagent.URI.type?(uri, :user), do: {:ok, uri}, else: {:error, {:bad_target_uri, uri}}

      other ->
        {:error, {:bad_target_uri, other}}
    end
  end
end
