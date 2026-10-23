/// Duman Messenger mesh simulator — the authoritative engine.
///
/// Implements the control plane and data plane specified in
/// `docs/03-smart-router-algorithm.md` (BATMAN-lite OGMs, coverage-score
/// election, MPR flood suppression, Spray-and-Wait DTN) over the radio model in
/// `docs/05-offline-mesh-protocol-stack.md` §1.1, driven by a deterministic
/// discrete-event clock.
///
/// The TypeScript simulator in `../../src` is the visual reference
/// implementation; both engines assert against the same golden vectors in
/// `../../test-fixtures/golden-vectors.json`.
library;

export 'src/election.dart';
export 'src/events.dart';
export 'src/rf.dart';
export 'src/rng.dart';
export 'src/routing.dart';
export 'src/scenarios.dart';
export 'src/simulation.dart';
export 'src/transport.dart';
export 'src/types.dart';
