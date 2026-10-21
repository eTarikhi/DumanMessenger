# Skill 07 — Power & Background Resilience

**Goal:** Mesh stays alive without killing battery or getting OS-killed silently.

### Android
- ForegroundService `connectedDevice` + persistent notification: “Duman Mesh • X peers • Y queued”
- `WorkManager` + `BOOT_COMPLETED` receiver to restart after reboot
- Request `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` with rationale dialog
- Handle scan limits: coalesce start/stop, never >5/30s [1](https://www.silabs.com/documents/public/application-notes/an1200-0-bluetooth-mesh-1x-for-android-and-ios-adk.pdf)
- Duty cycle: NORMAL `scan 3s/sleep 7s`, SUPER `continuous` (user-visible toggle)

### iOS
- `Info.plist`: `bluetooth-central`, `bluetooth-peripheral`, `audio` (for PTT)
- State preservation: `centralManagerOptionRestoreIdentifierKey`
- Document: “Mesh works best in foreground on iPhone — background = discovery only”
- Background refresh to advertise briefly every ~15 min (iOS throttled [2](https://topflightapps.com/ideas/develop-ble-app/))

### Telemetry
- Battery %/h per role, scans/sec, relays/sec, wake-locks

### Acceptance
- [ ] Android 8h NORMAL: <15% extra drain vs idle (Battery Historian)
- [ ] Android killed → WorkManager restarts service within 15 min
- [ ] iOS background: still beacons, reconnects on foreground without manual toggle
