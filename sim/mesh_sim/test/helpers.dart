import 'dart:math' as math;

import 'package:duman_mesh_sim/mesh_sim.dart';

/// Minimal node builder for unit tests. Defaults are a healthy, well-connected
/// handset so each test only overrides what it cares about.
MeshNode makeNode(
  String id,
  double x,
  double y, {
  double battery = 0.8,
  bool charging = false,
  double uptimeMin = 120,
  double mobility = 0,
  double pdr = 0.95,
  Role role = Role.normal,
  double score = 0,
  int seq = 0,
  bool stationary = true,
  bool isOnline = true,
  double wanderRadius = 10,
  double txPower = defaultTxPowerDbm,
}) {
  final n = MeshNode(
    id: id,
    name: id,
    pos: Vec2(x, y),
    battery: battery,
    charging: charging,
    uptimeMin: uptimeMin,
    mobility: mobility,
    pdr: pdr,
    stationary: stationary,
    home: Vec2(x, y),
    target: Vec2(x, y),
    wanderRadius: wanderRadius,
    txPower: txPower,
  );
  n.role = role;
  n.score = score;
  n.seq = seq;
  n.isOnline = isOnline;
  return n;
}

RfParams rfWith([List<Obstacle> obstacles = const <Obstacle>[]]) =>
    RfParams(obstacles: obstacles);

/// A ring of [count] peers around a centre node, all inside radio range.
List<MeshNode> ring(int count, {double radius = 12}) {
  final centre = makeNode('centre', 50, 50);
  final peers = <MeshNode>[centre];
  for (var i = 0; i < count; i++) {
    final a = (i / count) * 2 * math.pi;
    peers.add(makeNode('p$i', 50 + math.cos(a) * radius, 50 + math.sin(a) * radius));
  }
  return peers;
}
