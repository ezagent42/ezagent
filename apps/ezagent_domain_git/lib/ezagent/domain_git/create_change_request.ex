defmodule Ezagent.DomainGit.CreateChangeRequest do
  @moduledoc """
  Provider-neutral request to create a change request.

  `commit_date` is required and has no default (design
  docs/superpowers/specs/2026-07-25-git-provider-v1-plan-e-provider-owned-loop-design.md
  §6.1 step 5, corrected 2026-07-27 P3-fix3): it is the wall-clock time an
  adapter must stamp on the underlying Git commit's `author`/`committer`
  `date` so that a retried commit-create is byte-identical to the first
  attempt and reproduces the SAME sha. The caller (the workflow, Slice P4)
  populates it from `git_workflow_runs.inserted_at` -- the moment the run was
  durably accepted, written once and never touched again on retry. A missing
  or malformed `commit_date` fails construction rather than silently
  defaulting to a fabricated or wall-clock value.
  """

  alias Ezagent.DomainGit.{CommitSha, RepositoryRef, ValidationError}
  @fields [:title, :body, :head_ref, :expected_base_sha, :commit_date]
  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          title: String.t(),
          body: String.t(),
          head_ref: String.t(),
          expected_base_sha: CommitSha.t(),
          commit_date: DateTime.t()
        }

  @doc "Builds a validated provider-neutral request to create a change request."
  @spec new(term()) :: {:ok, t()} | {:error, ValidationError.t()}
  def new(attrs) do
    with :ok <- ValidationError.validate_attrs(attrs, @fields, &validate_values/1) do
      {:ok, struct!(__MODULE__, attrs)}
    end
  end

  defp validate_values(attrs) do
    cond do
      not ValidationError.nonempty_string?(attrs.title) ->
        {:error, {:invalid_field, :title}}

      not is_binary(attrs.body) ->
        {:error, {:invalid_field, :body}}

      not RepositoryRef.valid_ref?(attrs.head_ref) ->
        {:error, {:invalid_field, :head_ref}}

      not valid_commit_sha?(attrs.expected_base_sha) ->
        {:error, {:invalid_field, :expected_base_sha}}

      not valid_commit_date?(attrs.commit_date) ->
        {:error, {:invalid_field, :commit_date}}

      true ->
        :ok
    end
  end

  defp valid_commit_sha?(%CommitSha{value: value}),
    do: CommitSha.valid_sha1?(value) and value == String.downcase(value)

  defp valid_commit_sha?(_value), do: false

  # `match?(%DateTime{}, value)` alone only proves shape: a hand-built struct
  # (bypassing the smart constructors -- `DateTime.new/2`, `DateTime.utc_now/0`,
  # the `~U` sigil -- which all validate and would reject it) can carry an
  # out-of-range field such as `month: 13` and still match. `Calendar.ISO`'s
  # own `valid_date?/3` and `valid_time?/4` are the calendar-validity check
  # (leap years, month lengths, hour/minute/second/microsecond ranges) --
  # delegating to them proves the value denotes a real instant without
  # reimplementing any calendar rule here. `Calendar.ISO` is hardcoded rather
  # than read from the struct's `:calendar` field: every `commit_date` this
  # module will ever see traces back to an Ecto `utc_datetime` column
  # (`git_workflow_runs.inserted_at`, see moduledoc), which is always
  # `Calendar.ISO`, and dispatching to whatever `:calendar` atom a hand-built
  # struct happened to carry would let a bogus, non-callback-implementing
  # atom crash this check with `UndefinedFunctionError` instead of failing
  # closed with `{:error, {:invalid_field, :commit_date}}`.
  #
  # The `is_integer` guard keeps this function total. Unlike `match?/2`,
  # `Calendar.ISO.valid_date?/3` and `valid_time?/4` raise `FunctionClauseError`
  # on a non-integer field (e.g. a hand-built struct with `microsecond: nil`)
  # rather than returning `false` -- confirmed empirically, not assumed -- and
  # a validator that can itself crash the caller instead of returning
  # `{:error, _}` would be worse than the bug it fixes.
  defp valid_commit_date?(%DateTime{
         year: year,
         month: month,
         day: day,
         hour: hour,
         minute: minute,
         second: second,
         microsecond: {microsecond, precision}
       })
       when is_integer(year) and is_integer(month) and is_integer(day) and
              is_integer(hour) and is_integer(minute) and is_integer(second) and
              is_integer(microsecond) and is_integer(precision) do
    Calendar.ISO.valid_date?(year, month, day) and
      Calendar.ISO.valid_time?(hour, minute, second, {microsecond, precision})
  end

  defp valid_commit_date?(_value), do: false
end
