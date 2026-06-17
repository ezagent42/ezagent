defmodule EzagentPluginLoom.Tools.Now do
  @moduledoc """
  Returns the current server-side time. Useful for AI-generated
  pages that need a trusted timestamp (form submission times, "today
  is" displays, log entries). The browser's `Date.now()` is
  client-clock-trusting; this is server-clock.

  Args:
      tz   (string, default "Asia/Shanghai")
      fmt  (string, default "iso")  — "iso" | "unix" | "rfc1123"

  Returns:
      {iso: "2026-06-02T11:23:45+08:00", unix: 1748844225, tz: "Asia/Shanghai"}

  All three representations regardless of `fmt` so the AI page picks
  what it wants; `fmt` is a hint, not a filter.
  """

  @behaviour EzagentPluginLoom.Tool

  @impl true
  def name, do: "now"

  @impl true
  def description, do: "服务端当前时间(可信时间戳),返回 iso/unix/tz 三件套"

  @impl true
  def args_schema do
    %{
      "tz" => %{type: "string", default: "Asia/Shanghai", doc: "IANA 时区名"}
    }
  end

  @impl true
  def call(args, _ctx) when is_map(args) do
    tz = Map.get(args, "tz", "Asia/Shanghai")

    now_utc = DateTime.utc_now()

    shifted =
      case DateTime.shift_zone(now_utc, tz) do
        {:ok, dt} -> dt
        {:error, _} -> now_utc
      end

    {:ok,
     %{
       "iso" => DateTime.to_iso8601(shifted),
       "unix" => DateTime.to_unix(now_utc),
       "tz" => shifted.time_zone
     }}
  end

  def call(_args, _ctx), do: {:error, :bad_args}
end
