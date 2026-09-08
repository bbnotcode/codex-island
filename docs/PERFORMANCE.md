# Rendering performance

## Keep history preparation outside interaction updates

`OverviewView` observes cost data and constructs the current-year snapshot.
`OverviewContent` receives that snapshot as a value and owns provider/day
selection. Its model reference is used for actions, not observation: resizing
the island should not invalidate the history summary. Page changes are received
as events to clear day details without rebuilding the grid when no day is selected.

Do not put the calendar join back in a computed property read by each summary,
accessibility label, and grid. That repeats date arithmetic and provider aggregation
several times within a single view update. Cost publications still refresh the
snapshot, including new dates and provider records.

Contribution cells have a fixed width. Their provider segments use that width
directly, avoiding a geometry reader and an extra layout pass for each active day.
Keep per-day hover, selection, help text, and accessibility intact when changing
how the grid is drawn.

## Reproduce transition stalls

Run `scripts/benchmark-rendering.sh` from a logged-in graphical macOS session.
It builds a separate demo app, mounts the real `ExpandedView`, and repeatedly
changes pages and both chart styles for twelve seconds. The first two seconds
are warm-up. It does not start application polling, scan session logs, or start
the updater; preferences belong to a separate benchmark bundle.

The output reports main-run-loop timer intervals: p95, p99, maximum, and the
number of gaps over 25 ms. These are a signal for main-thread stalls, **not
measured display FPS or GPU presentation times**. The timer requests 120 Hz;
macOS scheduling and other running apps affect the results. Compare repeated
runs on the same machine with the same workload, and do not run other builds
or tests during the measurement.

For before/after comparison of history changes, set
`RENDER_BENCHMARK_OVERVIEW_SOURCE` to a saved copy of `OverviewView.swift`.
Both versions then use the same harness and compiler options. Use
`RENDER_BENCHMARK_PREVIEW=1 scripts/benchmark-rendering.sh` to leave the demo
window open for manual checks; stop the process afterward.

The benchmark covers content transitions, not the outer island glow, material
halo, mouse tracking, or Settings. Profile those separately before attributing
cost to them. Remaining candidates include the continuously shaded glow,
blurred chart transitions, and keeping offscreen carousel pages mounted.
Any page-unmounting optimization must preserve provider selection, outgoing
transition content, rapid navigation, and the first-use carousel cue.

## Expanded panel frame pacing

The carousel uses `CompositedPageStrip`: one native hosting layer moves with
Core Animation while its SwiftUI page layout stays in place. The animation
requests the window's display maximum, up to 120 FPS; effective Low Power Mode
(app preference or system mode) requests a maximum of 30 FPS. The rate is read
from the actual window screen on each movement. Interrupted navigation starts
from the presentation layer's current position. Geometry-only changes do not
start new page animations.

The cost count-up timeline uses the same 120/60/30 policy and stops when settled.
This policy is scoped to expanded content. The compact/peek glow schedule is
unchanged, and no persistent display-link loop is added to boost idle refresh.
Command-click chart cycling is handled inside the nested hosting view.

Core Animation frame-rate ranges are scheduling requests, not guarantees of
physical presentation. Other SwiftUI animations (such as chart-style fades)
remain system-paced; this is not a global rendering throttle for all UI.

Run `scripts/benchmark-rendering.sh Tests/PageStripTests.swift` to verify rate
selection, initial placement, page movement, low-power changes, and disabled
animation placement. The navigation benchmark now seeds usage demo data too,
so results from before that change are not a like-for-like chart workload.
