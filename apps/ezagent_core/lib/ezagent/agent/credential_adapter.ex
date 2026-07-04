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

  @optional_callbacks [refresh_test_credentials: 3, credential_status: 2]

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
end
