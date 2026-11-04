# Skill 07 — Power & Background Resilience

**Goal:** Mesh stays alive without killing battery or getting OS-killed silently.

### Android
- ForegroundService `connectedDevice` + persistent notification: “Duman Mesh • X peers • Y queued”
- `WorkManager` + `BOOT_COMPLETED` receiver to restart after reboot
- Request `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` with rationale dialog
- Handle scan limits: coalesce start/stop, never >5/30s [1](https://www.silabs.com/documents/public/application-notes/an1200-0-bluetooth-mesh-1x-for-android-and-ios-adk.pdf)
- Duty cycle: NORMAL `scan 3s/sleep 7s`, SUPER `continuous` (user-visible toggle)
  - **Modelled in both simulator engines** (`dutyCycleEnabled`, `normalScanWindowMs` 3000, `normalScanCycleMs` 10000, `sleepDrainFactor` 0.25; toggle in the config panel, per-node phase spread by index so a crowd does not sleep in lockstep). Only *scanning* is throttled — an asleep node keeps beaconing and keeps relaying what its route table covers, which is the BLE asymmetry above. Measured effect: `docs/06-simulator-findings.md` §10.4.

### iOS
- `Info.plist`: `bluetooth-central`, `bluetooth-peripheral`, `audio` (for PTT)
- State preservation: `centralManagerOptionRestoreIdentifierKey`
- Document: “Mesh works best in foreground on iPhone — background = discovery only”
- Background refresh to advertise briefly every ~15 min (iOS throttled [2](https://topflightapps.com/ideas/develop-ble-app/))

### Telemetry
- Battery %/h per role, scans/sec, relays/sec, wake-locks
  - **First three implemented and measured** in both engines (`batteryPercentPerHourNormal`/`Super`, `scansPerSec`, `relaysPerSec`, plus `awakeRatio`, `scansSkippedAsleep`, `electionEvents` and `latencyByHop`), surfaced in the React metrics dashboard and in `dart run bin/mesh_sim.dart --json`. The battery rate is *measured* from a snapshot taken at `clearRecords`, not read off the drain model, so it reflects the real role mix and charging. **All four are now implemented and measured** in both engines: wake-locks landed as `wakeLocks`, `wakeLockMs`, `wakeLockShareNormal`/`Super` and `radioDemandRatio`, with per-node `wakeLocksFor`/`wakeLockMsFor`. They were originally declined as an Android API artefact with no mesh-protocol counterpart (`docs/06-simulator-findings.md` §10.5, now carrying a dated amendment), and the objection still governs *how*: no cost per lock is invented — the accounting charges only durations the engine already computed for its contention model, plus one beacon at the existing per-hop unit. Two things came out of counting them, both against this engine's own assumptions: the model demands **3.9×** the radio time that exists at 20 nodes, so wake locks are reported as a **split between roles** rather than a percentage of a device's day; and the documented 4× battery gap between roles rests on a calibrated constant in `src/rf.ts` (`SUPER_DRAIN_PER_HOUR = (0.15/8) * 4`) whose direction and rough magnitude this skill's own duty cycle independently reproduces: NORMAL is awake **0.333** of the clock (`campus_quad`) and pays `sleepDrainFactor` **0.25** while asleep, so its effective rate halves while a SUPER's stays at 1.0 — a scan-duty ratio of **3.00×**, and a measured battery ratio that *widens* from 2.98× to **4.23×** when the duty cycle is on (5.51× on `festival_crowd`). Wake locks add a small third term: SUPERs are 25 % of nodes and hold 28.7 % of packet radio demand, 1.14× their share — which is a statement about packet work, not an estimate of the energy gap, and was once quoted here as one. The role cost still missing is the Wi-Fi Direct group-owner's, which the engine charges nothing for. `docs/06-simulator-findings.md` §24, whose §24.1 carries the correction.

### Acceptance
- [ ] Android 8h NORMAL: <15% extra drain vs idle (Battery Historian)
  - **Device measurement still pending; the simulator says the budget needs the duty cycle.** An always-scanning NORMAL node measures 15.0% per 8 h when perfectly still (`NORMAL_DRAIN_PER_HOUR` is `0.15/8` by construction — the budget, with zero headroom) and **19-25% per 8 h** once mobility is included. With `scan 3s/sleep 7s` at 25% sleep drain it measures **8.7-12.4% per 8 h** across `campus_quad` and `festival_crowd`, delivery-neutral on the seed mean. CI gates the <15% figure in `--duty-cycle` mode only, because asserting it on the always-on arm would fail on a true statement about the model rather than on a defect. `docs/06-simulator-findings.md` §10.3.
- [ ] Android killed → WorkManager restarts service within 15 min
- [ ] iOS background: still beacons, reconnects on foreground without manual toggle
