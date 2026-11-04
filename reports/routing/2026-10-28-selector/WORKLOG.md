# Durable execution ledger

1. Phase 0: verified clean branch arena/ff85cb12-dumanmessenger at c74b164, fetched origin
   (same HEAD), no reset. Read prior raw tables, strategy libraries, benchmark, verification,
   gate/recordDelivery/retry code in both engines. No production app exists. Local Dart absent.
2. Protocol frozen before new measurements/model fitting; see PROTOCOL.md. Existing raw
   evidence identifies regression seed31415 duty-cycle, 104 vs91 five-hop deliveries.
3. Reproduction completed before fitting: campus42 baseline148/ACK149; crowd31415 duty
   baseline104/ACK91, relay/retry counts match retained evidence exactly. Static diagnosis
   loses the 13-message gap (69/69 duty), but does not establish causality.
4. Added opt-in independent motion stream in both engines; default stream untouched.
   Paired positions and connectivity match exactly: controlled seed31415 duty103/94,
   always107/104. Thus routing-dependent mobility RNG is a confound but not a complete
   explanation: a negative ACK-6000 effect persists with matched movement.
5. Local selector implemented per source; baseline/shadow/canary all leave actual timers
   and forwarding untouched. Model/schema/drift faults latch baseline. Shared safety fixture,
   power override, dwell/hysteresis/rate limit, model immutability, engine shadow identity tested.
6. Seed606 progress-log contamination recorded in PROTOCOL.md; new final909 reserved before
   fitting and never used for fitting/tuning. Model frozen and SHA256 recorded before its run.
7. Training completed with standard-library Python only. Finite stump search chooses baseline
   in BOTH leaves, confidence0: there is no positive training gain for either eligible neighbor
   partition. Model hash ef63fbf524cb9ad056a0bd91fb1360330ad87c2518b64af74a748b47b4319c95.
   This is an experimental degenerate learned policy, not evidence of successful optimization.
8. First selector CI failed honestly: new Dart import was before the library directive,
   a compile error not caught by delimiter/declaration checks. Moved it after library;
   do not count run40642147624 as passed. Subsequent CI is required.
9. Frozen final909 evaluated once after fit: actual crowd always116/125 baseline/ACK,
   duty122/118. The model remains baseline/baseline; no holdout-based refit or activation.
   The exposed606 split is excluded from final statistics and renamed exposed-audit in flat
   summaries (raw original labels retained to preserve training dataset hash).
10. Shadow validation: eight scenario/power pairs, 150 messages each, exact full stats and
    delivery equality. Measured artifact115 bytes and sandbox-only timing; no phone memory claim.
11. Completed full local TS suite: 20 files/504 passed, 361.08 s atadac00d; focused final
    selector20 and Python7 passed. CI40642776402 at19024ab passed9/9: TS504 and Dart344/0/0.
    Source runtime/tool tree is unchanged since19024ab; final changes are retained evidence/docs.
12. Default and canary remain baseline-only. No main merge, online learning, paid dependency,
    phone deployment or production-approved model. Resume future work from the protocol, hashes
    and gates, not by repeating the historical360-run grid.
