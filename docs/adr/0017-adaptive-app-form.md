# Adaptive app form: window-following activation policy with an opt-out silent launch

The GUI returns to runtime activation-policy switching, this time driven entirely by the workspace window's own NSWindow lifecycle: while the workspace window is open the app presents as a regular app (Dock icon, app switcher, default menu bar); when it closes the app returns to the menu-bar accessory baseline. `LSUIElement` stays in the Info.plist so launches never flash a Dock icon and the unit-test host stays clean; the policy is applied from `didBecomeKey` (→ regular) and `willClose` (→ accessory) notifications of the window captured by a zero-size anchor view embedded in the scene content, so the target window is matched by object identity and sheets or auxiliary windows can never drive the switch. `NSApp.setActivationPolicy` is the only AppKit surface. A new inline-toggled **silent launch** preference (off by default, persisted in its own file) suppresses launch presentation so launches start in the menu-bar baseline; it takes effect on the next launch.

## Status

Accepted (2026-09-29). Supersedes ADR-0016's constant menu-bar-only form. The scene model, launch presentation, and status-menu reopening from 0016 carry over unchanged; only the "never a Dock icon" rule is replaced. The 2026-09-24 hybrid's AppKit window adapter stays gone — no window ownership, no opening-intent adapter, no delegate.

## Considered options

- Drive the switch from the window scene's `scenePhase`: attempted first and rejected after real-machine testing — on macOS `scenePhase` follows the application, not the window; closing the window (close button or ⌘W alike) fires no phase event, so the Dock icon never returned to accessory.
- Keep the constant accessory form (ADR-0016): rejected — the user wants a Dock icon exactly while the workspace window is open, and the window is presented at every launch by default, so the constant-accessory rule no longer matches the product.
- Distinguish login-item launches from manual launches and present the window only for the latter: rejected — `SMAppService.mainApp` launches are indistinguishable in-process, so the distinction would need unreliable launch-reason machinery. The silent-launch preference replaces it as an explicit user choice that applies to every launch.
- Persist silent launch as a field of settings.json: rejected — the proxy controller persists settings as whole in-memory snapshots, so any parallel writer's field would be clobbered by the controller's next write; a separate one-purpose store follows the `ActivationStateFileStore` precedent and keeps the runtime controller chain from consuming a GUI presentation preference.

## Consequences

- While the workspace window is open the app gains a Dock icon, app-switcher and Cmd-Tab presence, and the default SwiftUI menu bar (⌘W/⌘Q come with it; no custom commands are added yet).
- With silent launch off, every launch — including login-item launches — presents the window and therefore the Dock icon until the user closes it; with silent launch on, launches start silent and proxy runtime restoration still happens at every launch.
- ⌘H hiding orders the window out without posting `willClose`, so hiding is never mistaken for closing: the current form is kept and the Dock icon stays available to unhide.
- With silent launch on, the scene's pre-built but unpresented window triggers no policy change (not visible, never key): launches start and stay accessory until the user opens the window.
- The preference is inline-toggled and persisted immediately; it affects only the next launch, and a persistence failure keeps the toggle at its previous value and names the reason.
