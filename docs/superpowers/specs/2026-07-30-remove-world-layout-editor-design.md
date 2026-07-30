# Remove World Layout Editor Design

## Goal

Remove the unused World layout-editor feature completely. Chat and every other
World route render their route-defined, single-surface layout only; users never
see or manage a configurable multi-component page layout.

## Scope

- Remove the `layout_editor` renderer, its front-end component, and the
  `layout.manage` browser event.
- Remove the server-side layout manager and its persisted `world-layouts`
  resource type, including the bootstrap capability grant and behavior.
- Remove layout-related route state, permissions, dispatch contracts, slot
  declarations, migrations, and tests.
- Delete the obsolete layout files without reading or migrating them. They are
  intentionally incompatible with the resulting application.

## Architecture

`WorldLive` will bootstrap from the resolved route's fixed single-surface
layout, rather than the prior two-component fallback. The asynchronous state
load continues to enrich the route with caller, capability, session, and plugin
data, but it cannot cause a layout-editor surface to appear.

`LiveStateBuilder` remains the source of route-specific state. It will build a
single layout directly from the route component and title, with no persisted
layout store or caller-specific layout-management permission.

The React island renders only the server-provided route component. It no longer
contains layout editing controls or a fallback that implies a configurable
screen.

## Error Handling

If route data is still loading or a later state refresh fails, the browser
continues to display the fixed route surface. There is no alternative editor
layout and no layout persistence operation to fail.

## Verification

- Add/adjust server tests proving that Chat bootstraps and refreshes as a
  single `sessions_table` surface and its markup/state never contains
  `layout_editor`.
- Remove tests that verify layout persistence, grants, dispatch, or editing.
- Run the affected Elixir and front-end tests, then the project precommit
  check before opening the PR.
