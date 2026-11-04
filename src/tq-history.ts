import type { NextHopEntry, NodeId, TqWindow } from './types';

/** Same insertion-ordered Map, with live-key indexes for pruning by origin/via.
 * No routing decisions, sample values, RNG or serialized node state change.
 * Index storage is O(live history keys); delete/clear release both references.
 */
export class TqHistory extends Map<string, TqWindow> {
  declare private readonly origins: Map<NodeId, Set<string>>;
  declare private readonly vias: Map<NodeId, Set<string>>;

  constructor() {
    super();
    Object.defineProperties(this, {
      origins: { value: new Map() }, vias: { value: new Map() },
    });
  }

  private add(index: Map<NodeId, Set<string>>, id: NodeId, key: string): void {
    let keys = index.get(id);
    if (!keys) { keys = new Set(); index.set(id, keys); }
    keys.add(key);
  }

  private remove(index: Map<NodeId, Set<string>>, id: NodeId, key: string): void {
    const keys = index.get(id)!;
    keys.delete(key);
    if (!keys.size) index.delete(id);
  }

  override set(key: string, value: TqWindow): this {
    if (!this.has(key)) {
      const sep = key.lastIndexOf('|');
      this.add(this.origins, key.slice(0, sep), key);
      this.add(this.vias, key.slice(sep + 1), key);
    }
    super.set(key, value);
    return this;
  }

  override delete(key: string): boolean {
    if (!super.delete(key)) return false;
    const sep = key.lastIndexOf('|');
    this.remove(this.origins, key.slice(0, sep), key);
    this.remove(this.vias, key.slice(sep + 1), key);
    return true;
  }

  override clear(): void {
    super.clear(); this.origins.clear(); this.vias.clear();
  }

  prune(peers: ReadonlySet<NodeId>, routes: Record<NodeId, NextHopEntry>): void {
    // Deletion during Map/Set iteration is specified not to skip remaining keys.
    for (const [via, keys] of this.vias) {
      if (!peers.has(via)) for (const key of keys) this.delete(key);
    }
    for (const [origin, keys] of this.origins) {
      if (!routes[origin]) for (const key of keys) this.delete(key);
    }
  }
}
