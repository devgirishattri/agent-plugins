# Capture descriptors

A descriptor declares one capture route. It states what the route can observe,
record or drive, what it needs, how it leaves the host, and what it must never
do. The shape is `scripts/descriptor.schema.json`. Shipped descriptors live in
`scripts/descriptors/<id>.json`; the file stem equals `id`.

Descriptors are data, not automation. The walkthrough reuses tools the
workspace already configures. It does not install tools, change permissions,
select another device, or build a per-vendor driver framework.

## Observe versus drive

Capture tools observe. They cannot execute a user journey. A journey is
performed by an optional separately declared driver or by explicit manual
steps written in the assignment packet. `capabilities.drive` says which:

| Value | Meaning |
|---|---|
| `none` | The route observes only; the executor performs the journey by hand |
| `manual` | Same as `none`, documented for routes where no driver exists |
| `optional-driver` | A separately configured driver may perform the journey; capture still works without it |

Nothing in this plugin replays actions that may change application state.

## Recording kinds

| Kind | Meaning |
|---|---|
| `stills` | Individual screenshots |
| `continuous` | A real screen recording at the tool's native frame rate |
| `frame-sampled` | Frames captured at an interval and assembled; must report `frame_interval_seconds` |

A sequence of stills is never presented as a continuous recording. Clips are at
most 180 seconds; prefer short chapters. H.264 MP4 normalization is optional.
It needs an ffmpeg build with a compatible encoder; record the actual tool,
codec and any failure reason. Original formats may be kept.

## Shipped descriptors

| Id | Platform | Route | Tier | Pilot |
|---|---|---|---|---|
| `web-chrome-devtools` | web | Configured `chrome-devtools-mcp` screenshots of the selected origin | floor | not recorded |
| `macos-screencapture` | macos | Window-scoped `screencapture` stills and timed video | floor | not recorded |
| `ios-simulator-simctl` | ios-simulator | `xcrun simctl io` screenshot and `recordVideo --codec h264` | floor | not recorded |
| `android-emulator-adb` | android-emulator | `adb` screencap and `screenrecord` | floor | not recorded |

"Floor" means no capture dependency beyond platform tooling. It still requires
Xcode tools or `adb` where listed and never implies UI driving. A target is
supported only when its descriptor's `pilot.recorded` is true. That entry names
the host and the recorded outcome. No pilot has been recorded for any
descriptor yet.

Explicitly outside the first pilot: physical iOS and Android devices (Android
may get a probe-only path later), Windows and Linux native apps, and browser
emulation presented as native coverage. Electron apps use an already exposed
CDP endpoint through the web route, otherwise `macos-screencapture`; never
launch a new debugging endpoint implicitly.

Optional adapters (Playwright CLI/MCP, Peekaboo capture-only, MobileBuildMCP,
mobile-mcp, Maestro local flow recording) are research leads. Each needs a
license, telemetry, upload and permission audit before a descriptor exists.
`mobile-mcp`'s `mobilecli` dependency carries FSL terms; Peekaboo's live video
was reported frame-sampled; MobileBuildMCP reports errors to Sentry by default.

## Prerequisites and probes

`prerequisites` list commands, permissions, configuration, devices and tools.
A missing prerequisite yields a typed unavailable reason in the manifest: a
`skipped` or `failed` chapter with its reason. It never triggers an
installation, a permission change or an automatic device switch.

`probe` is a fixed read-only argv for availability and version detection. It
never captures, installs or reconfigures. macOS Screen Recording and
Accessibility permissions belong to the host application process, not to a tmux
pane; a probe can report their absence but must not trigger a grant prompt.

## Egress and telemetry

`egress.default` records what the tool does without configuration.
`opt_outs` list the researched or verified switches. Known leads, all
`researched` and not locally verified:

| Tool | Switch |
|---|---|
| chrome-devtools-mcp | `--no-usage-statistics`, `--no-performance-crux` |
| MobileBuildMCP | `MOBILEBUILDMCP_SENTRY_DISABLED=true` |
| mobile-mcp | `MOBILEMCP_DISABLE_TELEMETRY`; never enable its remote `--listen` route |
| Maestro | `MAESTRO_CLI_NO_ANALYTICS` |

A route whose required opt-outs cannot be expressed in validated configuration
is unavailable. No route may fall back to AI analysis, a cloud device service,
an unauthenticated listener or a remote renderer. Provider hook matchers do not
cover browser or native MCP calls; descriptors are a documented boundary, not a
network or process sandbox.
