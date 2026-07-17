# Enterprise first day: registration to first collaboration

This guide is for a team owner using Ezagent for the first time. Every step is available in the browser; no `mix` command or database edit is required.

## Get access

Open `/register`:

- With public registration enabled, enter an email, display name, and password. Ezagent creates one new workspace and makes the registrant its owner.
- With public registration closed, submit an access request. The response is deliberately uniform and does not reveal whether the email is already known.
- With an invite, open `/register?invite=...`. A valid invite works even while public registration is closed and only joins the workspace that issued it.

Confirm the email, then sign in. Interactive login now enters the product directly; developer PAT delivery is not a mandatory interstitial.

## Create an Agent and Session

Use **Create Agent** on Overview, choose a flavor, and name the Agent. The list shows its display name, flavor, status, and immutable URI.

If a model call reports a missing key, follow the provided Agent **Keys** link. The Agent creator or a workspace owner can manage keys for Agents in that workspace; stored values are only shown masked.

Create a Session with the `default` template, add the Agent, and mention it in chat. Save repeatable team setups as Session Templates from the workspace page.

## Invite teammates

Open **Manage → Workspace → Registration invites**, choose a use limit and expiry, then create and copy the registration link. Revoke links that are no longer needed. Revocation blocks future registrations but does not remove existing members.

Treat invite links as temporary workspace credentials. Do not put them in public tickets, channels, or repositories.

## Administrator controls

Open **Manage → Admin → Settings** to control public registration, require workspace invites, and review pending access requests. For production, keep public registration closed by default and use short-lived, limited-use invites.

## Troubleshooting

- Invalid invite: ask its issuer for a new link; it may be expired, exhausted, or revoked.
- Invite management is hidden: the current identity lacks the workspace capability or a different workspace is selected.
- Agent keys are read-only: switch to the correct workspace or ask the Agent creator/workspace owner.
- Confirmation email is missing: verify SMTP and send a test from **Admin → Settings**.
