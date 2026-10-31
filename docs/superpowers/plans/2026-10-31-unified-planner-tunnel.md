# Unified Planner and Tunnel Dimming Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Preserve the existing checkout and do not commit unrelated changes.

**Goal:** Ship one iOS route-planning flow and navigation-aware tunnel dimming using the existing BLE protocol.

**Architecture:** Reuse the existing driving and independent route engines behind one planner and navigation flow. Keep transient tunnel state in Settings; a Foundation-only policy and route classifier consume verified SDK evidence, and Settings owns effective brightness and BLE fading.

**Tech Stack:** Swift, SwiftUI, existing AMap SDK 10.1.600 and Search 9.7.5, existing macOS CLI test harnesses.

**Spec:** docs/superpowers/specs/2026-10-31-unified-planner-tunnel.md

## Global Constraints

- Only iOS, its tests, build checks and documentation; no Android/firmware edits or new dependencies.
- Keep driving routing and motorcycle-share-to-driving behavior; preserve personal Bundle IDs, Key storage, signing and prior changes.
- Do not silently discard unsupported waypoints or turn unverified service privileges into default dependencies.
- Use monotonic time for debounce and fading; unknown location never means tunnel exit.

## Task 1: Pure tunnel policy and route classification

Files: create ios/MotoNav/TunnelDimming.swift and ios/tests/tunnel-dimming/main.swift.

Interfaces: TunnelEvidence (unknown/outside/approaching/inside); TunnelDimmingPolicy.isDimmed, update(_:now:), reset(), targetBrightness(normal:night:dimmed:), nextBrightness(current:target:); TunnelRoute.Link(metres:isTunnel:), TunnelRoute(segments:), evidence(segment:link:metresToEndOfLink:).

- [x] Write tests for approach at times 0/0.8, immediate inside, outside at 10/11/12/13, unknown and long-gap cancellation, indices, NaN distances, lookahead across segments and adjacent tunnels.
- [x] Implement only the deterministic Foundation policy and classifier; no hardware, SDK or settings access.
- [x] Verify: swiftc ios/MotoNav/TunnelDimming.swift ios/tests/tunnel-dimming/main.swift -o /tmp/motonav-tunnel && /tmp/motonav-tunnel.

## Task 2: One destination and planning flow

Files: ContentView.swift, IndependentRouteView.swift, WebMotor.swift, NaviBridge.swift, ios/tests/ios-fixes/check.py.

- [x] Replace the separate planning entrances with one destination selection and TravelMode picker (driving/motorcycle/bicycle).
- [x] Extend the existing planner page to show SDK or independent route previews with the same actions. Keep prior input until a mode supports it; explicit validation for bicycle waypoints.
- [x] Route history, favorites and imported shares through the same flow; preserve motorcycle share driving strategy.
- [x] Invalidate pending independent and driving plans on mode/input changes; guard session ownership and active navigation.
- [x] Exercise production planner callbacks with SDK/network boundaries replaced; verify stale response, mode changes and waypoint validation.

## Task 3: Tunnel evidence and effective brightness

Files: Settings.swift, NaviBridge.swift, NaviScreen.swift, WebMotor.swift, ContentView.swift, project.pbxproj, ios/tests/ios-fixes/check.py, build checks.

- [x] Cache route link types for each active driving route. Validate SDK location freshness, accuracy, path matching, indices and duplicate timestamps before classifying evidence.
- [x] Compute current-link remaining geometry without using raw GPS loss as evidence; forward classification to Settings.
- [x] Add transient/manual tunnel state, auto setting, effective night palette and effective brightness. Fade on normal changes; forced reconnect applies current target immediately.
- [x] Clear temporary state on session finish; expose automatic scope and a tunnel shortcut in the common overlay.
- [x] Verify policy, Settings state/commands, forced reconnect, reset, existing clock, route and arrival regressions.

## Task 4: Review and phone delivery

- [x] Review mode/input lifecycle, stale callbacks, share imports, brightness races and restoration.
- [x] Render the shared planning/navigation UI when useful, build arm64 iPhone and verify signing.
- [x] Update the diagnostic source copy while retaining traffic-light probing, increment integrated version to 0.16.0 build 13, install and launch on the connected iPhone.
- [x] Update release/testing notes, record checks, and report road-test limits explicitly.

## Integration follow-up authorized by user

- Merge upstream0ef6d639 (9commits, iOS0.16.0Build12) while preserving local changes and personal app identity. Snapshot5cfa905 and backup branch codex/ios-before-upstream-20261031 retained.
- Restore all12 selectable firmware map styles; preserve style preferences and reject native/material packet mismatches.
- Independent review found invalid SDK link types could appear outside; fixed and re-reviewed, unknown evidence retains dimming. Policy suite now124 checks.
- Corrected upstream maps test fixture paths to production cache generation3; 670map checks pass.
- All CLI regression groups pass; signed arm64 Debug build13 compiles, app/extension signatures and device provisioning verified. Build13 installed and launched successfully on the unlocked iPhone; process19670 verified running.
