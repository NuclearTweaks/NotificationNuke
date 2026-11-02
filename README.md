# NotificationNuke

**Per-app notification sound cooldowns + regex text filters.**

A group chat that won't stop pinging? After the first notification from an app makes noise, every further one is **silent but still shown** — lock screen, Notification Center, banner, badge: all normal, just no sound — until the app's cooldown window expires. The next notification then sounds and restarts the timer. Default cooldown: **2 minutes**, configurable per app (0–60 min, or never mute).

And those "you have a streak to protect!" daily reminders? Give the app a **regex filter** (up to 3 per app) and any notification whose title/subtitle/body matches is **blocked completely** — no banner, no lock screen, no badge, nothing.

Install: add `https://nucleartweaks.github.io/` in Sileo/Cydia (rootless, iOS 15+).

## Settings

Settings → NotificationNuke:

- **NotificationNuke enabled** — global kill switch.
- **Default cooldown (min)** — slider 0–60, default 2. 0 = never mute.
- **Apps** — per-app list:
  - **Custom cooldown** switch + per-app slider (turn the switch off to follow the global default).
  - **Regex filters 1–3** — case-insensitive patterns matched against `title + "\n" + subtitle + "\n" + body`, e.g. `Get up|daily reminder`. A match drops the notification entirely.

Changes apply live — the Settings pane writes the preference domain and `usernotificationsd` reloads on the spot (Darwin notification). No respring.

## How it works

iOS delivers every notification through `usernotificationsd`, and both entry points hand the tweak the request and its bundle id together:

- push: `-[_queue_deliverNotificationRequest:bundleIdentifier:message:enforcePushType:]` on `UNCRemoteNotificationServer`
- local / scheduled: `-addNotificationRequest:forBundleIdentifier:withCompletionHandler:` on `UNUserNotificationServiceConnection`

One filter pass runs at those choke points:

1. **Regex** — any filter match returns "drop": the original never runs, the request is never saved, no completion-side side effects.
2. **Cooldown** — if the app made a sound within its window, the request is replaced with an identical rebuilt copy with `sound` stripped (requests are immutable). Outside the window it passes through untouched and the timestamp is recorded.

Everything lives in a single daemon, so the state machine is trivial and ordering is guaranteed. The rebuild is class-agnostic (uses the request's own class + `mutableCopy` content) so any private request subclass the pipeline hands us is handled.

`PreferenceLoader` provides the Settings pane; `Depends: mobilesubstrate` is resolved at runtime (`-undefined dynamic_lookup`), never linked against a concrete substrate.

## Verification (JB simulator)

The full injection + decision path is proven on the iOS 27 JB sim (`usernotificationsd` loads the tweak; ctor logs `pushHook=1 connHook=1`) and a built-in sim-only self-test runs the real decision layer against KVC request/content objects on every daemon start:

```
installed (enabled=1 default=120s perApp=0 pushHook=1 connHook=1)
MUTED com.nucleartweaks.selftest (sound silent, 120s cooldown left: st 2)
BLOCKED com.nucleartweaks.selftest (regex match on: st 3)
MUTED com.nucleartweaks.selftest (sound silent, 120s cooldown left: st 4)
SELFTEST pass1=1 mute2=1 drop3=1 mute4=1 → ALL PASS
```

The self-test (and the verbose REQ trace) are gated on a host-shared path that only exists on the dev sim — they never run on a device.

## Limitations / notes

- Sound only: banners, badges and lock-screen rows are untouched (by design). Critical alerts follow the same cooldown as normal sounds.
- The regex block runs before save, so blocked notifications are unrecoverable (that's the point).
- Timestamps persist best-effort under the daemon's `Library/Caches` (its sandbox decides); worst case cooldowns reset on respring.
- Foreground-app notification presentation (when an app shows its own banner while open) is decided client-side and is not re-filtered here.
- End-to-end delivery (an actual chime suppressed) can't be exercised on the bare JB sim (stub UserNotifications frameworks, no authorized notifier apps); the hooks are the documented UNS server choke points and the decision layer self-tests on every daemon load. Real-device confirmation tracked as the v1.0.x follow-up.

## Development

Org-standard scaffold — pipeline lives in `NuclearTweaks/.github` (reusable `tweak-ci.yml`).

* Local sim loop: `tools/sim-test.sh NotificationNuke` from the workspace root (Mac + JB-13mini; CI never builds for sim).
* Restart `usernotificationsd` after redeploy: `kill -9` it and trigger with `xcrun simctl push` (on-demand daemon; must respawn via the GUI domain to get injected).
* Release: push to `main` → CI opens a release PR → merge → GitHub Release + APT repo update.
* `Package:` id `com.nucleartweaks.notification-nuke` is immutable after the first release. See the org KB (`meta` repo → knowledge/pitfalls.md).
