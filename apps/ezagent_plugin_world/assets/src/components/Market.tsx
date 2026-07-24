import React from "react"
import {ArrowDownToLine, Globe, Lock, Store, Upload} from "lucide-react"

import {Badge, Button, EmptyState} from "./ui/primitives"
import type {SocialwareRow} from "./SessionsTable"

// PR-5 §15 — the socialware market browse surface. Cards are server-scoped
// (`DefinitionRegistry.list/1` visibility), so this renderer shows exactly what
// the caller may install; 上架/下架 buttons only appear on the caller's OWN
// workspace definitions — the actual authz (#165 public-scope gate for
// publish, manage+admin for retract) is enforced server-side and a denial
// surfaces loud via `market_error` / the error toast.
export type MarketState = {
  component?: string
  socialwares?: SocialwareRow[]
  workspace_uri?: string | null
  market_notice?: string | null
  market_error?: string | null
  create_error?: string | null
}

type MarketProps = {
  state?: MarketState
  onAction?: (action: string, args: Record<string, unknown>) => void
}

export function MarketSurface({state, onAction}: MarketProps) {
  const socialwares = state?.socialwares || []
  const workspaceUri = state?.workspace_uri || null
  const error = state?.market_error || state?.create_error || null

  return (
    <section className="grid min-w-0 gap-4" data-world-component="market">
      {error && (
        <p
          className="rounded-md border border-destructive/40 bg-destructive/10 px-3 py-2 text-sm text-destructive"
          role="alert"
          data-world-market-error
        >
          {error}
        </p>
      )}
      {state?.market_notice && (
        <p
          className="rounded-md border border-border bg-muted/40 px-3 py-2 text-sm text-foreground"
          data-world-market-notice
        >
          {state.market_notice}
        </p>
      )}

      {socialwares.length === 0 ? (
        <EmptyState label="当前没有可安装的社交软件。" />
      ) : (
        <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3" data-world-market-cards>
          {socialwares.map((socialware) => (
            <MarketCard
              key={`${socialware.workspace_uri || ""}:${socialware.name}`}
              socialware={socialware}
              own={socialware.workspace_uri === workspaceUri}
              onAction={onAction}
            />
          ))}
        </div>
      )}
    </section>
  )
}

function MarketCard({
  socialware,
  own,
  onAction,
}: {
  socialware: SocialwareRow
  own: boolean
  onAction?: (action: string, args: Record<string, unknown>) => void
}) {
  const isPublic = socialware.scope === "public" || socialware.public === true
  const installable = Boolean(socialware.config_id)

  return (
    <div
      className="grid gap-3 rounded-md border border-border bg-card p-4"
      data-world-market-card={socialware.name}
      data-world-market-scope={isPublic ? "public" : "private"}
      data-world-market-own={own ? "true" : "false"}
    >
      <div className="flex min-w-0 items-start justify-between gap-2">
        <div className="min-w-0">
          <p className="truncate text-sm font-semibold text-foreground">
            {socialware.title || socialware.name}
          </p>
          <p className="truncate font-mono text-[11px] text-muted-foreground">{socialware.name}</p>
        </div>
        <div className="flex flex-none items-center gap-1.5">
          {own && <Badge tone="info">own</Badge>}
          {isPublic ? (
            <Badge tone="success">
              <Globe aria-hidden="true" className="mr-1 h-3 w-3" />
              public
            </Badge>
          ) : (
            <Badge tone="default">
              <Lock aria-hidden="true" className="mr-1 h-3 w-3" />
              private
            </Badge>
          )}
        </div>
      </div>

      <p className="line-clamp-3 min-h-[2.5rem] text-xs text-muted-foreground">
        {socialware.description || "（无描述）"}
      </p>

      <div className="flex min-w-0 items-center gap-2 text-[11px] text-muted-foreground">
        <Store aria-hidden="true" className="h-3 w-3 flex-none" />
        <span className="truncate font-mono">{workspaceLabel(socialware.workspace_uri)}</span>
        {socialware.version && <span className="flex-none">v{socialware.version}</span>}
      </div>

      <div className="flex items-center gap-2 border-t border-border pt-3">
        <Button
          type="button"
          size="sm"
          disabled={!installable}
          data-world-market-install={socialware.name}
          onClick={() =>
            onAction?.("market.install", {
              name: socialware.name,
              config_id: socialware.config_id,
              content_hash: socialware.content_hash,
            })
          }
        >
          <ArrowDownToLine aria-hidden="true" />
          安装
        </Button>
        {own && !isPublic && (
          <Button
            type="button"
            size="sm"
            variant="secondary"
            data-world-market-publish={socialware.name}
            onClick={() => onAction?.("market.publish", {name: socialware.name})}
          >
            <Upload aria-hidden="true" />
            上架
          </Button>
        )}
        {/* 下架 (retract) / restore are SERVICE-ONLY: the socialware manage cap
            is not user-holdable (string subject, service-ctx only), so no World
            user could ever authorize it — shipping the button would always fail.
            Retract/restore run on the service path (Socialware.retract/2). */}
      </div>
    </div>
  )
}

function workspaceLabel(uri?: string | null): string {
  if (!uri) return "unknown"
  return uri.replace(/^workspace:\/\//, "")
}
