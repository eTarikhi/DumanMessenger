import type { MeshNode, Obstacle, Vec2 } from "./types";
import type { Rng } from "./rng";
import { chance, randRange } from "./rng";

/**
 * RF model (docs/05 §1.1, skills/08).
 *
 *   rssi(d) = txPowerDbm - 20*log10(d) - wallCrossings * wallPenaltyDb
 *
 * Calibration: with the defaults below (tx -55 dBm, sensitivity -85 dBm) the
 * free-space hop range is ~31 m and a single interior wall pulls it in to ~18 m,
 * which matches the documented "BLE 10-30 m indoors, ~100 m open air" budget.
 * The previous prototype used tx -30 dBm over an 800x600 canvas, which produced
 * a 562 m radio in a world 8x too large for the documented 100x100 m test area —
 * the mesh came up disconnected and nothing could be elected or delivered.
 */

export const DEFAULT_TX_POWER_DBM = -55;
export const DEFAULT_RX_SENSITIVITY_DBM = -85;
export const DEFAULT_WALL_PENALTY_DB = 12;

/** Walking speed for mobility = 1.0, in metres per simulated second. */
const MAX_SPEED_MPS = 1.4;

export interface RfParams {
  txPowerDbm: number;
  rxSensitivityDbm: number;
  wallPenaltyDb: number;
  obstacles: Obstacle[];
}

export function distance(a: Vec2, b: Vec2): number {
  return Math.sqrt((a.x - b.x) ** 2 + (a.y - b.y) ** 2);
}

/** Maximum line-of-sight range in metres for the given RF parameters. */
export function maxRangeM(p: Pick<RfParams, "txPowerDbm" | "rxSensitivityDbm">): number {
  return Math.pow(10, (p.rxSensitivityDbm - p.txPowerDbm) / -20);
}

function orient(ax: number, ay: number, bx: number, by: number, cx: number, cy: number): number {
  const v = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
  if (v > 1e-12) return 1;
  if (v < -1e-12) return -1;
  return 0;
}

function segmentsIntersect(
  p1: Vec2,
  p2: Vec2,
  p3: Vec2,
  p4: Vec2
): boolean {
  const d1 = orient(p3.x, p3.y, p4.x, p4.y, p1.x, p1.y);
  const d2 = orient(p3.x, p3.y, p4.x, p4.y, p2.x, p2.y);
  const d3 = orient(p1.x, p1.y, p2.x, p2.y, p3.x, p3.y);
  const d4 = orient(p1.x, p1.y, p2.x, p2.y, p4.x, p4.y);
  if (((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))) {
    return true;
  }
  return false;
}

/** Number of obstacle boundaries crossed by the segment a->b (0, 1 or 2). */
export function countWallCrossings(a: Vec2, b: Vec2, obstacles: Obstacle[]): number {
  let crossings = 0;
  for (const o of obstacles) {
    const tl: Vec2 = { x: o.x, y: o.y };
    const tr: Vec2 = { x: o.x + o.w, y: o.y };
    const br: Vec2 = { x: o.x + o.w, y: o.y + o.h };
    const bl: Vec2 = { x: o.x, y: o.y + o.h };
    let c = 0;
    if (segmentsIntersect(a, b, tl, tr)) c++;
    if (segmentsIntersect(a, b, tr, br)) c++;
    if (segmentsIntersect(a, b, br, bl)) c++;
    if (segmentsIntersect(a, b, bl, tl)) c++;
    // A segment fully inside the building is blocked like two walls.
    crossings += c === 0 && insideObstacle(a, o) && insideObstacle(b, o) ? 2 : c;
  }
  return crossings;
}

export function insideObstacle(p: Vec2, o: Obstacle): boolean {
  return p.x > o.x && p.x < o.x + o.w && p.y > o.y && p.y < o.y + o.h;
}

/** A handset cannot be inside a building; used to reject bad spawn points. */
export function insideAnyObstacle(p: Vec2, obstacles: Obstacle[]): boolean {
  for (const o of obstacles) if (insideObstacle(p, o)) return true;
  return false;
}

export function rssiModel(from: MeshNode, to: MeshNode, p: RfParams): number {
  const d = Math.max(1, distance(from.pos, to.pos));
  const walls = countWallCrossings(from.pos, to.pos, p.obstacles);
  return p.txPowerDbm - 20 * Math.log10(d) - walls * p.wallPenaltyDb;
}

/** Map -100..-30 dBm onto 0..1 (docs/03 §3). */
export function normRssi(rssi: number): number {
  return Math.max(0, Math.min(1, (rssi + 100) / 70));
}

export function linkQuality(from: MeshNode, to: MeshNode, p: RfParams): number {
  return normRssi(rssiModel(from, to, p));
}

/**
 * Probability that one transmission over this link is lost.
 *
 * Driven by the *link margin* above receiver sensitivity rather than by the
 * normalised RSSI, so a close link is effectively lossless and a link at the
 * edge of range is bad but not hopeless:
 *
 *   margin 30 dB -> 0 %   |  15 dB -> 11 %  |  8 dB -> 24 %  |  0 dB -> 45 %
 *
 * Lossy links are what make the PDR term of the coverage score meaningful: a
 * node whose neighbours keep dropping packets should not be elected SUPER.
 * Pure arithmetic (no transcendentals beyond the path-loss log) so the Dart
 * port is bit-identical.
 */
export const LOSS_AT_ZERO_MARGIN = 0.45;
export const LOSS_MARGIN_FLOOR_DB = 30;

/** Raw (single-attempt) loss for this link. */
export function packetLossProbability(from: MeshNode, to: MeshNode, p: RfParams): number {
  const margin = Math.max(
    0,
    Math.min(LOSS_MARGIN_FLOOR_DB, rssiModel(from, to, p) - p.rxSensitivityDbm)
  );
  const deficit = 1 - margin / LOSS_MARGIN_FLOOR_DB;
  return LOSS_AT_ZERO_MARGIN * deficit * deficit;
}

/**
 * Loss actually seen by the application layer.
 *
 * BLE GATT writes and Wi-Fi Direct sockets are *reliable* bearers: the link
 * layer retransmits before the failure is ever reported upwards. Modelling a
 * single attempt therefore overstates loss by an order of magnitude and made
 * the mesh look far worse than the documented targets. With `retries` extra
 * attempts the residual loss is p^(retries+1):
 *
 *   20 m, 2 retries -> 34 % raw becomes 3.9 % app-visible
 *   30 m, 2 retries -> 44 % raw becomes 8.3 % app-visible
 */
export function effectiveLossProbability(
  from: MeshNode,
  to: MeshNode,
  p: RfParams,
  retries: number
): number {
  const raw = packetLossProbability(from, to, p);
  let loss = 1;
  for (let i = 0; i <= retries; i++) loss *= raw;
  return loss;
}

export function canReach(from: MeshNode, to: MeshNode, p: RfParams): boolean {
  if (from.id === to.id) return false;
  return rssiModel(from, to, p) > p.rxSensitivityDbm;
}

export function peersInRange(node: MeshNode, allNodes: MeshNode[], p: RfParams): MeshNode[] {
  const out: MeshNode[] = [];
  for (const n of allNodes) {
    if (n.id !== node.id && n.isOnline && canReach(node, n, p)) out.push(n);
  }
  return out;
}

/**
 * Waypoint mobility (skills/08: "random walk + waypoint clusters").
 *
 * A node walks towards a waypoint near its home position and picks a fresh
 * waypoint when it arrives or when the renewal roll fires. This keeps a crowd
 * behaving like a crowd: people mill around the café terrace instead of
 * crossing the whole site and silently isolating themselves, which a pure
 * random walk does within a few simulated minutes.
 *
 * RNG draw order (renewal roll, then angle + radius when renewing) is part of
 * the cross-language contract with the Dart port.
 */
export const WAYPOINT_RENEWAL_PROBABILITY = 0.05;
export const WAYPOINT_ARRIVAL_M = 1.5;

export function integrateMotion(
  node: MeshNode,
  rng: Rng,
  dtSec: number,
  areaW: number,
  areaH: number,
  mobilityEnabled: boolean
): void {
  if (!mobilityEnabled || node.stationary || node.mobility <= 0) return;

  const renew = chance(rng, WAYPOINT_RENEWAL_PROBABILITY);
  const distToTarget = distance(node.pos, node.target);
  if (renew || distToTarget < WAYPOINT_ARRIVAL_M) {
    const angle = randRange(rng, 0, Math.PI * 2);
    const rad = node.wanderRadius * Math.sqrt(rng());
    node.target.x = clamp(node.home.x + Math.cos(angle) * rad, 2, areaW - 2);
    node.target.y = clamp(node.home.y + Math.sin(angle) * rad, 2, areaH - 2);
  }

  const dx = node.target.x - node.pos.x;
  const dy = node.target.y - node.pos.y;
  const d = Math.sqrt(dx * dx + dy * dy);
  if (d < 1e-9) return;
  const step = Math.min(d, node.mobility * MAX_SPEED_MPS * dtSec);
  node.pos.x = clamp(node.pos.x + (dx / d) * step, 2, areaW - 2);
  node.pos.y = clamp(node.pos.y + (dy / d) * step, 2, areaH - 2);
}

function clamp(v: number, lo: number, hi: number): number {
  return Math.max(lo, Math.min(hi, v));
}

/**
 * Battery model calibrated to the documented targets (docs/05 §1.2):
 * NORMAL must survive 8 h at <= 15 % drain, SUPER (continuous scan + Wi-Fi GO)
 * costs roughly 4x as much.
 */
export const NORMAL_DRAIN_PER_HOUR = 0.15 / 8;
export const SUPER_DRAIN_PER_HOUR = (0.15 / 8) * 4;
const CHARGE_PER_HOUR = 0.5;
const MOBILITY_DRAIN_PER_HOUR = 0.02;

export function batteryDrain(node: MeshNode, dtSec: number, multiplier: number): void {
  const dtHours = (dtSec / 3600) * multiplier;
  if (node.charging) {
    node.battery = Math.min(1, node.battery + CHARGE_PER_HOUR * dtHours);
    return;
  }
  const rate = node.role === "SUPER" ? SUPER_DRAIN_PER_HOUR : NORMAL_DRAIN_PER_HOUR;
  const drain = (rate + node.mobility * MOBILITY_DRAIN_PER_HOUR) * dtHours;
  node.battery = Math.max(0, node.battery - drain);
}
