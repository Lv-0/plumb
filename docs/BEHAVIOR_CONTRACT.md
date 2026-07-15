# Automatic Layout Behavior Contract

This file is the behavior-preserving baseline for the runtime refactor. It
records the latest implemented behavior where older README/AGENTS prose is
contradictory. Changing an item below is a product change and should be reviewed
separately from architecture work.

## Activation and completion

- Layout is scoped to an app activation cycle, not the entire process lifetime.
- Re-activating an app or changing Space starts a new evaluation cycle.
- Tiling wins when an app appears in both automatic-layout allowlists.
- A layout is complete only after a successful result/readback or an explicitly
  accepted fallback product. Merely starting an animation is not completion.
- Tile attempts are counted per window when an animation really starts, and
  when a synchronous completion still fails the target. An already-satisfied
  no-op consumes nothing.
- Valid tile requests from a multi-window enumeration are serialized in FIFO
  order. A closed/ineligible queued window is skipped without discarding later
  candidates, and a `busy` writer consumes no attempt budget.
- PID reuse does not define a new process as the old session: observer ownership
  also checks the kernel process-start timestamp and activation generation. A
  delayed termination notification cannot tear down an already-attached live
  replacement that reused the same PID.

## Manual window movement

The current implemented behavior is the baseline:

- A genuine user move or resize outside Plumb's animation/self-layout grace
  marks that window as manually placed.
- Plumb leaves that window untouched for the remainder of the current
  activation/Space cycle.
- The manual mark is cleared on app reactivation, Space change, app termination,
  and Plumb shutdown.
- Option is not currently required. Reintroducing an Option-only sticky mode is
  a separate product decision.

## Document applications

- Saved document windows with a non-empty `kAXDocument` value are tiled.
- An unsaved window whose AX subtree contains document-content roles is a real
  document. Each such window owns an independent stable gate; Plumb waits for
  its frame to stabilize, then tiles it through the shared FIFO.
- Template galleries and file lists are centered only and do not lock the PID or
  mark the window complete.
- An AX subtree that is not ready is `undetermined`: it may be centered for
  usability once, but its exact window owns an activation-scoped classification
  retry even if the app-level initial retry has already expired. Classification
  ticks do not repeatedly center or simulate AX notifications; they continue
  until the window becomes a gallery or document, or the bounded retry expires.
- A resolved document hands off from classification ownership to the same
  window's stable gate. A resolved gallery or persistent `undetermined` window
  remains unlocked, and another document cannot enumerate around either gate.
- Pages may replace a gallery/placeholder identity with a real document whose
  first callback is `AXResized`. At attach, Plumb seeds the activation's known
  window identities from `AXWindows`. Only a newly observed, eligible document
  identity can enter a 1.5-second startup bootstrap and begin classification
  from move/resize without becoming manual. Existing identities still become
  manual immediately; pointer-down evidence cancels bootstrap and wins as user
  intent. Bootstrap is exact-window/activation owned and cleared at every
  lifecycle boundary.
- Animated and synchronous-fallback center writes receive self-layout grace;
  an already-centered no-op does not. Delayed AX move notifications therefore
  do not freeze gallery/undetermined classification as a manual placement.

## Secondary and exceptional windows

- Dialogs, panels, modal/floating windows, and detected secondary windows are not
  centered or tiled.
- Chromium and ChatGPT Atlas prefer the structured AX identifier.
- Finder treats only `FinderWindow` as a main window.
- Safari/Firefox and other fallback cases use the main-window relationship when
  reliable.
- Journal Settings uses its localized static title because its other AX
  attributes are indistinguishable from the main window.
- These exclusions must be enforced before every geometry-writing path,
  including all-window/background enumeration. Move/resize observer paths do
  not write geometry; they only record manual state after their guards pass.

## Geometry and screens

- Per-app directional insets override global directional insets.
- The canonical tile target comes from `WindowGeometry.tiledFrame`.
- A height-constrained application may finish at the documented vertically
  anchored fallback product; width remains strict until a separate product
  decision says otherwise.
- Ambiguous coordinate evidence may fall back to the last high-confidence value,
  but zero-overlap evidence must not silently select the first display.
- Screen Recording is optional and only supplies additional CG evidence.
- If a foreground app omits `AXWindowNumber`, CG window geometry may support an
  already-tiled decision only when the closest same-PID window is unique for the
  exact AX element's current size. Target-sized or equal-scoring sibling windows
  cannot complete that element's tile operation without an AX read/write.

## Manual acceptance

Passing `swift test` does not prove AX runtime behavior. A release candidate must
also be exercised through the live matrix listed in `docs/ARCHITECTURE.md`.
