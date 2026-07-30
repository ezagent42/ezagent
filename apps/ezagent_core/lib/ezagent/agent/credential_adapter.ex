defmodule Ezagent.Agent.CredentialAdapter do
  @moduledoc """
  #17 — the flavor-generic agent credential contract. A flavor's **Template Class**
  implements this behaviour (the SAME module that materializes/wipes the agent's files,
  so the credential declaration can never drift from the materializer — codex review).

  Both credentialled flavors use ONE parameterized per-agent-file model: the agent's login
  state lives in a per-agent dir (allocated by `Ezagent.Sandbox.ConfigDir`, PR-3) that the
  flavor points its CLI at via an env var. The flavors differ only in parameters:

  | param | cc | codex |
  |---|---|---|
  | `credential_env_var/0` | `"CLAUDE_CONFIG_DIR"` | `"CODEX_HOME"` |
  | `credential_relpaths/0` | `[".credentials.json"]` | `["auth.json", "config.toml"]` |

  Flavors with no login state (curl/echo/np) implement NONE of these callbacks.

  ## All-or-none

  A Template Class that implements ANY credential callback MUST implement ALL of them
  (gated by `Ezagent.Invariants.CredentialAdapterContractTest`) — a flavor that declares
  where creds live but not how to detect expiry (or vice-versa) is an incomplete lifecycle.

  `refresh_test_credentials/2` (the ④ test/E2E provisioner) is added in PR-E and is NOT
  part of the all-or-none declarative core below.
  """

  @doc "The env var the flavor's CLI reads to locate its per-agent credential home."
  @callback credential_env_var() :: String.t()

  @doc "Files within the credential home that ARE the login state (for ① assert / ③ copy)."
  @callback credential_relpaths() :: [String.t()]

  @doc """
  The subset of files within the credential home that are pure SECRET/token material,
  copied ONLY from the single resolved credential source (§D6). Disjoint from config
  paths — codex `config.toml` is config (joins the layer merge), NOT a secret.
  """
  @callback secret_relpaths() :: [String.t()]

  @doc """
  PTY-output signatures meaning "auth expired/missing, needs re-login" (for ②). Pure data
  — the detector that consumes them lives in the PTY server (PR-C).
  """
  @callback auth_failure_signals() :: [Regex.t() | String.t()]

  @doc """
  Declares how an operator connects credentials for this Template Class.

  This callback is optional: omitting it means `:not_required`. When present,
  it returns either `{:pty, label}` for an interactive terminal login or
  `{:api_key, provider, label}` for an API-key prompt. The domain normalizes
  those declarations through `Ezagent.Agent.CredentialConnection`.
  """
  @callback credential_connection(keyword()) ::
              :not_required | {:pty, String.t()} | {:api_key, String.t(), String.t()}

  @doc """
  #17 PR-E (④, TEST/E2E ONLY) — provision valid credentials into an agent's config
  `home` from a `source` credential path (refresh-if-expired + copy), so E2E runs without
  a human login. SEPARATE from the declarative all-or-none group below (a flavor may
  declare the credential identity above without yet supporting test auto-provisioning).
  Guarded to non-:prod by callers.
  """
  @callback refresh_test_credentials(source :: String.t(), home :: String.t(), opts :: keyword()) ::
              :ok | {:error, term()}

  @doc """
  #160 (credential-status view) — read-only, non-activating classification of the
  agent's on-disk login state in its credential `home` dir. Returns the flavor's
  NORMALIZED status contribution — `status` is one of
  `Ezagent.Agent.CredentialStatus.status/0`, plus an optional human `detail` and
  (when the flavor can read one, e.g. cc's OAuth `expiresAt`) `expires_at` in
  epoch ms. MUST NOT do network I/O or activate the agent (mirror
  `EzagentPluginCc.CredentialFreshness`'s guarantees). SEPARATE from the
  declarative all-or-none group — a flavor may declare where creds live without
  yet supporting a status probe (the router then reports `:unknown`).
  """
  @callback credential_status(home :: String.t() | nil, opts :: keyword()) ::
              %{
                required(:status) => atom(),
                optional(:detail) => String.t() | nil,
                optional(:expires_at) => integer() | nil
              }

  @doc """
  #1201 A② (installer host-login inheritance) — the flavor's HOST login home on
  THIS node: where the flavor's CLI keeps the interactive operator login when no
  per-agent env var redirects it (cc: `$CLAUDE_CONFIG_DIR` else `~/.claude`;
  codex: `$CODEX_HOME` else `~/.codex`). Returns `nil` when the node has no
  such home. SEPARATE from the declarative all-or-none group — a flavor may
  declare the credential identity without exposing a host-login concept
  (the installer-inheritance seam then no-ops for it).
  """
  @callback host_login_dir() :: String.t() | nil

  @optional_callbacks [
    refresh_test_credentials: 3,
    credential_status: 2,
    host_login_dir: 0,
    credential_connection: 1
  ]

  @declarative_callbacks [
    {:credential_env_var, 0},
    {:credential_relpaths, 0},
    {:secret_relpaths, 0},
    {:auth_failure_signals, 0}
  ]

  @doc "The declarative credential callbacks (all-or-none group)."
  @spec declarative_callbacks() :: [{atom(), non_neg_integer()}]
  def declarative_callbacks, do: @declarative_callbacks

  @doc """
  True iff `class_module` declares a credential adapter (implements the full declarative
  group). False for credential-less flavors.
  """
  @spec credentialled?(module()) :: boolean()
  def credentialled?(class_module) when is_atom(class_module) do
    Code.ensure_loaded(class_module)

    Enum.all?(@declarative_callbacks, fn {name, arity} ->
      function_exported?(class_module, name, arity)
    end)
  end

  @doc """
  #1201 A② — the flavor's USABLE host-login source dir on this node, or `:none`.

  `{:ok, dir}` iff `class_module` is a credentialled flavor that exposes
  `host_login_dir/0`, the dir exists, AND it currently holds at least one of the
  flavor's `secret_relpaths/0` (a host home with no secret is "not logged in" —
  selecting it would reproduce the exact empty-credential symptom this seam
  exists to fix). Everything else — credential-less flavors (py/curl), flavors
  without a host-login concept, a missing/empty host home — is `:none`, so the
  installer-inheritance seam no-ops cleanly (DoD 4).
  """
  @spec host_login_source_dir(module()) :: {:ok, String.t()} | :none
  def host_login_source_dir(class_module) when is_atom(class_module) do
    Code.ensure_loaded(class_module)

    with true <- credentialled?(class_module),
         true <- function_exported?(class_module, :host_login_dir, 0),
         dir when is_binary(dir) and dir != "" <- class_module.host_login_dir(),
         true <- File.dir?(dir),
         true <-
           Enum.any?(class_module.secret_relpaths(), &File.exists?(Path.join(dir, &1))) do
      {:ok, dir}
    else
      _ -> :none
    end
  end
end
