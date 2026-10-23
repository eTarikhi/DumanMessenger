/// RF model (docs/05 §1.1, skills/08), mirroring `src/rf.ts`.
///
///     rssi(d) = txPowerDbm - 20*log10(d) - wallCrossings * wallPenaltyDb
///
/// Calibration: with the defaults below (tx -55 dBm, sensitivity -85 dBm) the
/// free-space hop range is ~31 m and a single interior wall pulls it in to
/// ~18 m, matching the documented "BLE 10-30 m indoors, ~100 m open air"
/// budget. The original prototype used tx -30 dBm over an 800x600 canvas, which
/// produced a 562 m radio in a world 8x too large for the documented 100x100 m
/// test area — the mesh came up disconnected and nothing could be elected.
library;

import 'dart:math' as math;

import 'rng.dart';
import 'types.dart';

const double defaultTxPowerDbm = -55;
const double defaultRxSensitivityDbm = -85;
const double defaultWallPenaltyDb = 12;

/// Walking speed for mobility = 1.0, in metres per simulated second.
const double maxSpeedMps = 1.4;

const double _ln10 = 2.302585092994046;

/// `dart:math` has no log10; dividing the natural log keeps the model identical
/// to the TypeScript engine to within a last-ULP, which the golden vectors
/// absorb via tolerance on float aggregates.
double _log10(double x) => math.log(x) / _ln10;

class RfParams {
  const RfParams({
    this.txPowerDbm = defaultTxPowerDbm,
    this.rxSensitivityDbm = defaultRxSensitivityDbm,
    this.wallPenaltyDb = defaultWallPenaltyDb,
    this.obstacles = const <Obstacle>[],
  });

  final double txPowerDbm;
  final double rxSensitivityDbm;
  final double wallPenaltyDb;
  final List<Obstacle> obstacles;

  RfParams copyWith({List<Obstacle>? obstacles}) => RfParams(
        txPowerDbm: txPowerDbm,
        rxSensitivityDbm: rxSensitivityDbm,
        wallPenaltyDb: wallPenaltyDb,
        obstacles: obstacles ?? this.obstacles,
      );
}

double distance(Vec2 a, Vec2 b) {
  final dx = a.x - b.x;
  final dy = a.y - b.y;
  return math.sqrt(dx * dx + dy * dy);
}

/// Maximum line-of-sight range in metres for the given RF parameters.
double maxRangeM(double txPowerDbm, double rxSensitivityDbm) =>
    math.pow(10, (rxSensitivityDbm - txPowerDbm) / -20).toDouble();

int _orient(double ax, double ay, double bx, double by, double cx, double cy) {
  final v = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
  if (v > 1e-12) return 1;
  if (v < -1e-12) return -1;
  return 0;
}

bool _segmentsIntersect(Vec2 p1, Vec2 p2, Vec2 p3, Vec2 p4) {
  final d1 = _orient(p3.x, p3.y, p4.x, p4.y, p1.x, p1.y);
  final d2 = _orient(p3.x, p3.y, p4.x, p4.y, p2.x, p2.y);
  final d3 = _orient(p1.x, p1.y, p2.x, p2.y, p3.x, p3.y);
  final d4 = _orient(p1.x, p1.y, p2.x, p2.y, p4.x, p4.y);
  return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
      ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0));
}

bool insideObstacle(Vec2 p, Obstacle o) =>
    p.x > o.x && p.x < o.x + o.w && p.y > o.y && p.y < o.y + o.h;

/// A handset cannot be inside a building; used to reject bad spawn points.
bool insideAnyObstacle(Vec2 p, List<Obstacle> obstacles) {
  for (final o in obstacles) {
    if (insideObstacle(p, o)) return true;
  }
  return false;
}

/// Number of obstacle boundaries crossed by the segment a->b (0, 1 or 2).
int countWallCrossings(Vec2 a, Vec2 b, List<Obstacle> obstacles) {
  var crossings = 0;
  for (final o in obstacles) {
    final tl = Vec2(o.x, o.y);
    final tr = Vec2(o.x + o.w, o.y);
    final br = Vec2(o.x + o.w, o.y + o.h);
    final bl = Vec2(o.x, o.y + o.h);
    var c = 0;
    if (_segmentsIntersect(a, b, tl, tr)) c++;
    if (_segmentsIntersect(a, b, tr, br)) c++;
    if (_segmentsIntersect(a, b, br, bl)) c++;
    if (_segmentsIntersect(a, b, bl, tl)) c++;
    // A segment fully inside the building is blocked like two walls.
    crossings += (c == 0 && insideObstacle(a, o) && insideObstacle(b, o)) ? 2 : c;
  }
  return crossings;
}

double rssiModel(MeshNode from, MeshNode to, RfParams p) {
  final d = math.max(1.0, distance(from.pos, to.pos));
  final walls = countWallCrossings(from.pos, to.pos, p.obstacles);
  return p.txPowerDbm - 20 * _log10(d) - walls * p.wallPenaltyDb;
}

/// Map -100..-30 dBm onto 0..1 (docs/03 §3).
double normRssi(double rssi) => ((rssi + 100) / 70).clamp(0.0, 1.0).toDouble();

double linkQuality(MeshNode from, MeshNode to, RfParams p) =>
    normRssi(rssiModel(from, to, p));

/// Probability that one transmission over this link is lost.
///
/// Driven by the *link margin* above receiver sensitivity rather than by the
/// normalised RSSI, so a close link is effectively lossless and a link at the
/// edge of range is bad but not hopeless:
///
///     margin 30 dB -> 0 %  |  15 dB -> 11 %  |  8 dB -> 24 %  |  0 dB -> 45 %
///
/// Lossy links are what make the PDR term of the coverage score meaningful: a
/// node whose neighbours keep dropping packets should not be elected SUPER.
const double lossAtZeroMargin = 0.45;
const double lossMarginFloorDb = 30;

/// Raw (single-attempt) loss for this link.
double packetLossProbability(MeshNode from, MeshNode to, RfParams p) {
  final margin = (rssiModel(from, to, p) - p.rxSensitivityDbm)
      .clamp(0.0, lossMarginFloorDb)
      .toDouble();
  final deficit = 1 - margin / lossMarginFloorDb;
  return lossAtZeroMargin * deficit * deficit;
}

/// Loss actually seen by the application layer.
///
/// BLE GATT writes and Wi-Fi Direct sockets are *reliable* bearers: the link
/// layer retransmits before a failure is ever reported upwards. Modelling a
/// single attempt overstates loss by an order of magnitude. With `retries`
/// extra attempts the residual loss is p^(retries+1):
///
///     20 m, 2 retries -> 34 % raw becomes 3.9 % app-visible
///     30 m, 2 retries -> 44 % raw becomes 8.3 % app-visible
double effectiveLossProbability(
    MeshNode from, MeshNode to, RfParams p, int retries) {
  final raw = packetLossProbability(from, to, p);
  var loss = 1.0;
  for (var i = 0; i <= retries; i++) {
    loss *= raw;
  }
  return loss;
}

bool canReach(MeshNode from, MeshNode to, RfParams p) {
  if (from.id == to.id) return false;
  return rssiModel(from, to, p) > p.rxSensitivityDbm;
}

List<MeshNode> peersInRange(MeshNode node, List<MeshNode> allNodes, RfParams p) {
  final out = <MeshNode>[];
  for (final n in allNodes) {
    if (n.id != node.id && n.isOnline && canReach(node, n, p)) out.add(n);
  }
  return out;
}

/// Waypoint mobility (skills/08: "random walk + waypoint clusters").
///
/// A node walks towards a waypoint near its home position and picks a fresh one
/// when it arrives or when the renewal roll fires. This keeps a crowd behaving
/// like a crowd: people mill around the café terrace instead of crossing the
/// whole site and silently isolating themselves, which a pure random walk does
/// within a few simulated minutes.
///
/// RNG draw order (renewal roll, then angle + radius when renewing) is part of
/// the cross-language contract with the TypeScript engine.
const double waypointRenewalProbability = 0.05;
const double waypointArrivalM = 1.5;

double _clamp(double v, double lo, double hi) => math.max(lo, math.min(hi, v));

void integrateMotion(
  MeshNode node,
  Rng rng,
  double dtSec,
  double areaW,
  double areaH,
  bool mobilityEnabled,
) {
  if (!mobilityEnabled || node.stationary || node.mobility <= 0) return;

  final renew = chance(rng, waypointRenewalProbability);
  final distToTarget = distance(node.pos, node.target);
  if (renew || distToTarget < waypointArrivalM) {
    final angle = randRange(rng, 0, math.pi * 2);
    final rad = node.wanderRadius * math.sqrt(rng());
    node.target.x = _clamp(node.home.x + math.cos(angle) * rad, 2, areaW - 2);
    node.target.y = _clamp(node.home.y + math.sin(angle) * rad, 2, areaH - 2);
  }

  final dx = node.target.x - node.pos.x;
  final dy = node.target.y - node.pos.y;
  final d = math.sqrt(dx * dx + dy * dy);
  if (d < 1e-9) return;
  final step = math.min(d, node.mobility * maxSpeedMps * dtSec);
  node.pos.x = _clamp(node.pos.x + (dx / d) * step, 2, areaW - 2);
  node.pos.y = _clamp(node.pos.y + (dy / d) * step, 2, areaH - 2);
}

/// Battery model calibrated to the documented targets (docs/05 §1.2): NORMAL
/// must survive 8 h at <= 15 % drain; SUPER (continuous scan + Wi-Fi GO) costs
/// roughly 4x as much.
const double normalDrainPerHour = 0.15 / 8;
const double superDrainPerHour = (0.15 / 8) * 4;
const double _chargePerHour = 0.5;
const double _mobilityDrainPerHour = 0.02;

void batteryDrain(MeshNode node, double dtSec, double multiplier) {
  final dtHours = (dtSec / 3600) * multiplier;
  if (node.charging) {
    node.battery = math.min(1.0, node.battery + _chargePerHour * dtHours);
    return;
  }
  final rate = node.role == Role.superNode ? superDrainPerHour : normalDrainPerHour;
  final drain = (rate + node.mobility * _mobilityDrainPerHour) * dtHours;
  node.battery = math.max(0.0, node.battery - drain);
}
