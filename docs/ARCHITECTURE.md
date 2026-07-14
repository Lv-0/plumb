# Plumb Runtime Architecture

This document separates the runtime boundaries implemented by the stability
refactor from the extraction work that is intentionally still staged. Product
behavior is characterized before ownership or scheduling changes, and
Accessibility quirks stay outside the pure geometry layer.

## Why the runtime is being split

Window automation is an asynchronous control system. Workspace activation,
Accessibility notifications, delayed application layout, animation ticks, and
screen changes can all race with one another. A Boolean "handled" result and a
collection of unrelated timer fields cannot express whether work succeeded,
was deferred, was superseded, or was cancelled by the user.

The former implementation concentrated these concerns in
`WindowEventObserver` and `WindowCenteringService`. That made every new
application exception another branch through shared PID locks and timers.

## Implemented runtime boundaries

```text
NSWorkspace / AXObserver
        |
        v
WindowEventObserver
  process incarnation + activation generation
  candidate eligibility + document/secondary classification
  manual/cycle state + token-owned continuations
        |
        +------------------------------+
        | tile requests                | center requests
        v                              v
LayoutSessionCoordinator       WindowCenteringService
  exact operation IDs            global writer lease
  duplicate suppression          coordinate resolution/cache
  FIFO promotion                 typed start result
        |                              |
        +--------------+---------------+
                       v
                WindowAnimator
          finished / writerFailed /
                userInterrupted
                       |
                       v
                WindowGeometry
                  pure math
```

Tile requests are queued explicitly because multi-document enumeration can
produce several valid windows at once. Center requests use the same global
service writer lease and report `busy` so bounded polling can retry them; they
cannot overwrite a tile or another center animation.

`WindowGeometry` remains pure. Application-specific classification stays in the
observer today and does not leak into coordinate or animation code.

## Runtime invariants

1. Every external event carries the PID that produced it and the activation
   generation under which its observer was attached.
2. A callback from an old generation is a no-op before any AX write.
3. At most one layout effect writes window geometry at a time. Additional
   windows are queued or explicitly rejected as busy; they never overwrite the
   active timer/session handle.
4. Completion is typed. Animation completion distinguishes `finished`,
   `userInterrupted`, and `writerFailed`; operation start distinguishes
   `started`, `completedSynchronously(didWriteGeometry:)`, and `busy`. A
   synchronous AX fallback write is therefore not confused with an
   already-at-target no-op when applying self-layout grace.
5. Only a verified success or an explicitly accepted fallback can lock a
   window session as settled.
6. Starting a skipped/busy operation does not consume the tile-attempt budget.
   A synchronous tile completion that still misses the target does consume it,
   preventing non-resizable windows from retrying forever.
7. Every delayed continuation is owned by an activation or window token and is
   cancellable at app activation, app termination, Space change, or shutdown.
8. Every geometry-writing path applies the same secondary-window and Journal
   Settings exclusions. Document galleries and undetermined windows never enter
   the tile FIFO.
9. Coordinate evidence can be unresolved. Zero-overlap and ambiguous CG
   candidates are not silently promoted to the first screen/window.
10. Settings and geometry behavior remain testable without AX permission.

## State model

The intended per-window lifecycle is:

```text
awaitingCandidate
  -> waitingForStable
  -> centering | tiling
  -> waitingForCorrection
  -> stabilizing
  -> settled

Any non-terminal phase -> manual | cancelled | failed
```

A session identity is `(processIncarnation, activationGeneration)`. The process
incarnation uses the kernel process-start timestamp, with `NSRunningApplication`
launch date as a fallback. A window identity combines PID, the positive AX
window number when available, and AX element identity; the operation sequence
prevents delayed same-window callbacks from causing an ABA completion.
If an old termination notification conflicts with a currently running lookup
for the observed PID, the live activation wins and is not torn down.

## Refactor status

- Implemented: typed animation/start outcomes, global writer lease, tile FIFO,
  activation generations, process-incarnation checks, exact timer ownership,
  bounded attempt accounting, cache invalidation, and stale callback rejection.
- Implemented: pure/testable state machines for activation ownership, FIFO
  promotion, continuation ownership, geometry, and screen overlap selection.
- Staged next: consolidate the observer's parallel per-window collections into
  a dedicated session store.
- Staged next: extract one immutable AX snapshot and a pure classification
  policy so role/document/secondary reads cannot disagree within one decision.
- Staged next: place AX reads/writes and coordinate resolution behind narrower
  interfaces after the signed live matrix confirms no behavior drift.

The staged items are maintainability boundaries, not hidden claims of runtime
validation. They should not be combined with behavior changes.

## Validation

Unit tests are necessary but not sufficient. Each runtime checkpoint also needs
manual validation with the signed app bundle because third-party applications
enforce different minimum sizes and expose inconsistent AX attributes.

The minimum live matrix includes Pages, Numbers, Word, Excel, Terminal, Safari,
a Chromium application, Finder secondary windows, Journal Settings, multiple
windows in one PID, multiple display arrangements, Screen Recording on/off,
and app switching during every animation phase.
