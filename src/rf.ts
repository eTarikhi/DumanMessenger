import type { MeshNode, Vec2 } from "./types";

const TX_POWER = -30;
const WALL_PENALTY = 12;

export function distance(a: Vec2, b: Vec2): number {
  return Math.sqrt((a.x - b.x) ** 2 + (a.y - b.y) ** 2);
}

export function rssiModel(from: MeshNode, to: MeshNode): number {
  const d = Math.max(1, distance(from.pos, to.pos));
  let rssi = TX_POWER - 20 * Math.log10(d);
  const walls = estimateWalls(from.pos, to.pos);
  rssi -= walls * WALL_PENALTY;
  return rssi;
}

function estimateWalls(a: Vec2, b: Vec2): number {
  const d = distance(a, b);
  if (d < 15) return 0;
  if (d < 30) return 1;
  if (d < 50) return 2;
  if (d < 70) return 2;
  return 3;
}

export function normRssi(rssi: number): number {
  return Math.max(0, Math.min(1, (rssi + 100) / 70));
}

export function canReach(from: MeshNode, to: MeshNode): boolean {
  const rssi = rssiModel(from, to);
  return rssi > -85;
}

export function linkQuality(from: MeshNode, to: MeshNode): number {
  const rssi = rssiModel(from, to);
  return normRssi(rssi);
}

export function peersInRange(node: MeshNode, allNodes: MeshNode[]): MeshNode[] {
  return allNodes.filter(
    (n) => n.id !== node.id && n.isOnline && canReach(node, n)
  );
}

export function randomWalk(node: MeshNode, areaW: number, areaH: number): void {
  if (node.stationary) return;
  const speed = node.mobility * 3;
  const angle = Math.random() * Math.PI * 2;
  node.pos.x = Math.max(10, Math.min(areaW - 10, node.pos.x + Math.cos(angle) * speed));
  node.pos.y = Math.max(10, Math.min(areaH - 10, node.pos.y + Math.sin(angle) * speed));
  node.uptimeMin += 0.05;
}

export function batteryDrain(node: MeshNode, dtSec: number): void {
  if (node.charging) {
    node.battery = Math.min(1, node.battery + 0.001 * dtSec);
    return;
  }
  const baseDrain = node.role === "SUPER" ? 0.0008 : 0.00015;
  const mobilityDrain = node.mobility * 0.00005;
  node.battery = Math.max(0, node.battery - (baseDrain + mobilityDrain) * dtSec);
}
