export type NodeId = string;
export type MsgId = string;

export type Role = "SUPER" | "NORMAL";
export type TransportType = "ble" | "wifiDirect" | "multipeer";

export type MsgType = "text" | "broadcast" | "voice" | "sos" | "ack" | "ogm";

export interface Vec2 {
  x: number;
  y: number;
}

export interface MeshMessage {
  id: MsgId;
  type: MsgType;
  from: NodeId;
  to: NodeId | "BROADCAST";
  destHint: string;
  body: string;
  ttl: number;
  hopCount: number;
  priority: "low" | "normal" | "high";
  timestamp: number;
  encrypted: boolean;
}

export interface OGM {
  nodeId: NodeId;
  seq: number;
  score: number;
  isSuper: boolean;
  peerCount: number;
  batteryBucket: number;
  bestHopTo: Record<string, number>;
}

export interface NextHopEntry {
  bestNeighbor: NodeId;
  tq: number;
  lastSeq: number;
  hopCount: number;
  lastSeen: number;
}

export interface QueuedMessage {
  msg: MeshMessage;
  createdAt: number;
  copyCount: number;
  ttlDays: number;
}

export interface MeshNode {
  id: NodeId;
  name: string;
  pos: Vec2;
  battery: number;
  charging: boolean;
  uptimeMin: number;
  mobility: number;
  pdr: number;
  role: Role;
  score: number;
  seq: number;
  peerCount: number;
  avgRssi: number;
  isOnline: boolean;
  reasonTrace: string;
  ogmTable: Record<string, OGM>;
  nextHopTable: Record<string, NextHopEntry>;
  neighborScores: Record<string, number>;
  seenCache: Map<string, number>;
  oppQueue: QueuedMessage[];
  inbox: MeshMessage[];
  sentLog: MeshMessage[];
  txPower: number;
  stationary: boolean;
  demoteCounter: number;
  wasSuper: boolean;
}
