# Website Kanban permission-aware published-read design

## Goal

Extend the existing Hello website product path so an author session can publish
a website that references a real Kanban board, and a separate reception session
can consume the published website with read-only Kanban access. Re-publishing
the same board updates the existing relationship by entity URI rather than
copying board data or creating duplicate boards.

This design continues on `feat/hello-recording-ready` / PR #1425. It depends on
the Kanban sharing and generic Mount contracts currently carried by #1374 and
#1376. Until those dependencies land on `main`, this branch may define and lock
the Hello-side contract, but it must not copy their implementation or claim a
live sharing path.

## Confirmed product model

There are two distinct runtime sessions:

- **Session 1 — author/operation session.** The website owner edits the Hello
  surface and operates the real Kanban board. It holds the write authority.
- **Session 2 — reception/published-consumption session.** The reception agent
  consumes a published website reference and receives read-only Kanban access.
  External visitors view the website through this session rather than joining
  the author's operation session.

Operation and publication are separate actions. Editing a page or board does
not silently broadcast changes to every reception session. The author performs
an explicit publish/update action, producing a new published revision that
continues to reference the same board entity.

## Ownership and storage

Kanban remains the sole owner of task state, board sharing policy, and
authorization. Hello and the website publication layer store only bounded
references and publication metadata:

- `board_uri` — the canonical Kanban entity URI;
- source author `session_uri`;
- the Kanban-produced share/receive reference or equivalent published-read
  descriptor;
- publication revision and timestamps needed by the website product flow.

They must not store a copied Kanban tree, mirror task status fields as a durable
read model, read the Kanban state slice directly, mint capabilities themselves,
or reproduce Kanban's sharing rules.

## Publication data flow

```text
Session 1: author website + real Kanban board
  explicit publish/update
        |
        v
Hello published-read adapter
  asks the Kanban sharing contract for a bounded read reference
  stores board_uri + publication metadata only
        |
        v
Session 2: reception website installation
  resolves the receiver's own eligible session/assistant
  mounts the referenced board through Kanban/Mount with access=:read
        |
        v
Visitor surface
  renders Hello content + current permission-authorized Kanban read data
  exposes no board mutation controls
```

The expected dependency contract, based on #1374, grants only
`[:get_tree, :export_markmap]` to the receiving session's
`kanban-assistant`. Capability minting and the durable mount row remain owned by
the generic Mount/Kanban implementation. Hello never calls `Cap.issue` or
writes capability storage directly.

## Idempotent update semantics

The stable identity is the Kanban entity URI, not a copied task list and not a
new board per publication.

Publishing the same `board_uri` again for the same receiving session must
converge on the existing mount/reference. It may advance publication metadata
or replace an expired share descriptor, but it must not create a duplicate
board, duplicate mount, or second Hello-owned task record.

Publishing a different `board_uri` is a distinct relationship. Removing a board
from a later website publication removes it from the published website view; it
does not delete the Kanban board itself.

## Hello-side adapter

The Hello side introduces a small replaceable boundary whose production
implementation is wired only after #1374/#1376 land:

```text
publish_board_read(author_ctx, source_session_uri, board_uri)
  -> {:ok, published_board_ref}
  -> {:error, :forbidden}
  -> {:error, :expired}
  -> {:error, :not_found}
  -> {:error, :no_target_session}
  -> {:error, :unavailable}
  -> {:error, :dependency_not_landed}

refresh_published_board(viewer_ctx, published_board_ref)
  -> {:ok, bounded_board_view}
  -> the same closed error vocabulary
```

`published_board_ref` contains identifiers and a Kanban-produced receive
reference, never board contents. `bounded_board_view` is supplied through the
authorized Kanban read contract and contains only fields that contract exposes.

Before the dependency lands, contract tests must fail honestly at the missing
production seam. A fake may exercise deterministic consumer error handling,
but fake output cannot be presented as a live sharing result.

## Product surface

### Author surface

The authenticated Hello website surface adds an explicit **Publish website
update** action separate from Kanban editing/delegation. A successful result
shows:

- the associated board reference;
- that the published access is read-only;
- the publication/update revision;
- a share or preview action supplied by the sanctioned contract.

### Reception and visitor surface

The published website shows the latest authorized Kanban projection alongside
the Hello page. It does not render add, rename, move, claim, status-edit, or
other mutation controls.

Anonymous visitors do not directly claim a Kanban share token or receive board
capabilities. The reception session/agent owns the read mount; visitors consume
the website's authorized public view through the existing socialware ingress.

## Closed failure behavior

- `:forbidden` — the author or reception caller lacks the required sharing/read
  authority. No reference or stale board detail is shown.
- `:expired` — the share descriptor expired. The author can explicitly
  re-publish; the visitor sees an expired/unavailable state.
- `:not_found` — the board was deleted or the entity reference is invalid.
- `:no_target_session` — the receiver has no eligible reception session with a
  `kanban-assistant` capable of holding the read mount.
- `:unavailable` — Kanban/Mount is temporarily unavailable. The stable reference
  may remain visible, but cached details are not labelled current.
- `:dependency_not_landed` — development-only honest boundary before
  #1374/#1376 are available on `main`.

Every refresh re-authorizes through Kanban. A previously successful read never
becomes continuing authority after sharing is revoked.

## Manifest composition

The website socialware definition composes the existing Hello and Kanban
capabilities through declared `uses`/`requires` relationships; it does not copy
Kanban roles, actions, recipes, or permission policy into Hello.

The final manifest shape must be validated against the dependency's landed
definition model. The intended product composition is conceptually:

```yaml
uses:
  - hello
  - kanban
```

If the landed #1374 model removes a board role from the Kanban manifest, the
website manifest must follow that model: the board remains an independently
owned passive entity mounted into a session, not a role that the website
materializes anew.

## Verification

Automated coverage must prove:

1. publishing stores only stable references and no copied Kanban tree;
2. the same `board_uri` published twice converges without duplicate mounts;
3. a reception assistant can dispatch `get_tree` but receives
   `:unauthorized` for a write action;
4. anonymous visitors receive no direct Kanban mutation or share-claim path;
5. revoked, expired, deleted, missing-session, and unavailable states do not
   leak stale board details;
6. all access flows through Invocation and the landed Kanban/Mount contract;
7. the website manifest composes Hello and Kanban without duplicating Kanban
   recipes or permission rules;
8. existing Hello generation, PATCH, concierge, anonymous view, and delegation
   regressions stay green.

Once #1374/#1376 land, browser evidence must drive two distinct sessions:

1. author edits the real Kanban board in Session 1;
2. author explicitly publishes the website update;
3. Session 2 receives/mounts the board read-only;
4. the published website displays the updated board state;
5. a write attempt from the reception side is denied;
6. re-publishing the same board updates in place;
7. screenshots, transcript, and a new recording capture the real flow.

## Scope boundaries

Included:

- explicit website publication/update of a Kanban read reference;
- permission-aware read refresh;
- entity-URI idempotent convergence;
- separate author and reception sessions;
- real product UI and evidence after dependencies land.

Excluded:

- copying or mirroring Kanban task data into Hello;
- automatic write-through from the visitor website;
- silently publishing on every board edit;
- putting all authors and visitors in one session;
- direct capability storage writes;
- GitHub/SSH credential handling;
- #1360-style implementation copied from an unmerged dependency branch.
