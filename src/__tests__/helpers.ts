import type { MeshNode, Obstacle, Vec2 } from "../types";
import type { RfParams } from "../rf";
import { DEFAULT_RX_SENSITIVITY_DBM, DEFAULT_TX_POWER_DBM, DEFAULT_WALL_PENALTY_DB } from "../rf";
import { DEFAULT_CONFIG, type SimConfig } from "../simulation";

/** Minimal node builder for unit tests. Defaults are a healthy, well-connected
 *  handset so each test only overrides what it cares about. */
export function makeNode(id: string, x: number, y: number, over: Partial<MeshNode> = {}): MeshNode {
  return {
    id,
    name: id,
    pos: { x, y } as Vec2,
    battery: 0.8,
    charging: false,
    uptimeMin: 120,
    mobility: 0,
    pdr: 0.95,
    role: "NORMAL",
    score: 0,
    seq: 0,
    peerCount: 0,
    avgRssi: -70,
    isOnline: true,
    reasonTrace: "test",
    ogmTable: {},
    nextHopTable: {},
    neighborScores: {},
    seenCache: new Map(),
    mprHeardSuper: new Set(),
    oppQueue: [],
    inbox: [],
    sentLog: [],
    txPower: DEFAULT_TX_POWER_DBM,
    stationary: true,
    demoteCounter: 0,
    wasSuper: false,
    home: { x, y },
    target: { x, y },
    wanderRadius: 10,
    lastPhysicsAt: 0,
    nextOgmAt: 0,
    nextScanAt: 0,
    tx: { outcomes: [], cursor: 0, filled: 0 },
    roleTransitions: 0,
    txCount: 0,
    mprSuppressed: 0,
    offlineAt: -1,
    ...over,
  };
}

export function rfWith(obstacles: Obstacle[] = [], over: Partial<RfParams> = {}): RfParams {
  return {
    txPowerDbm: DEFAULT_TX_POWER_DBM,
    rxSensitivityDbm: DEFAULT_RX_SENSITIVITY_DBM,
    wallPenaltyDb: DEFAULT_WALL_PENALTY_DB,
    obstacles,
    ...over,
  };
}

export function configWith(over: Partial<SimConfig> = {}): SimConfig {
  return { ...DEFAULT_CONFIG, ...over };
}

/** Distance between two nodes, for asserting hop geometry. */
export function dist(a: MeshNode, b: MeshNode): number {
  return Math.hypot(a.pos.x - b.pos.x, a.pos.y - b.pos.y);
}
