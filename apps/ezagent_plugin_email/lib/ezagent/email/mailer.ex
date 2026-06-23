defmodule Ezagent.Email.Mailer do
  @moduledoc """
  Swoosh mailer for the email plugin. Adapter is fixed per env:
  `Swoosh.Adapters.Local` in dev, `Swoosh.Adapters.Test` in test (both
  "non-SMTP" — always ready, no DB), `Swoosh.Adapters.SMTP` in prod (needs the
  runtime `smtp_config` from `Ezagent.AppSettings`).
  """
  use Swoosh.Mailer, otp_app: :ezagent_plugin_email
end
