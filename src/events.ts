/**
 * Deterministic discrete-event queue.
 *
 * The mesh is simulated as events on a virtual clock rather than as one
 * synchronous recursive burst. That is what makes latency, the MPR 300 ms wait
 * and TTL/expiry windows meaningful (docs/02 §6 "text delivery < 2 s 1 hop").
 *
 * Ordering is total: events are compared by (at, seq) so equal-timestamp events
 * run in insertion order and the TypeScript and Dart engines agree exactly.
 */

export type EventKind =
  | "physics"
  | "ogm"
  | "election"
  | "scan"
  | "msg"
  | "mpr"
  | "acktimeout"
  /** Repeat an SOS flood (docs/05: "SOS mode: repeated flood of GPS + text"). */
  | "sosrepeat"
  /** Put one push-to-talk frame on air at its capture time (docs/05 §3.3). */
  | "transferchunk"
  /** Re-send whatever a stalled transfer is still missing (docs/05 §3.2 "resume"). */
  | "transferstall"
  | "traffic";

export interface SimEvent<T = unknown> {
  at: number;
  seq: number;
  kind: EventKind;
  nodeId: string;
  payload?: T;
}

export class EventQueue {
  private heap: SimEvent[] = [];
  private seqCounter = 0;

  get length(): number {
    return this.heap.length;
  }

  clear(): void {
    this.heap = [];
    this.seqCounter = 0;
  }

  push(at: number, kind: EventKind, nodeId: string, payload?: unknown): void {
    this.heap.push({ at, seq: this.seqCounter++, kind, nodeId, payload });
    this.siftUp(this.heap.length - 1);
  }

  peek(): SimEvent | undefined {
    return this.heap[0];
  }

  pop(): SimEvent | undefined {
    const top = this.heap[0];
    const last = this.heap.pop();
    if (this.heap.length > 0 && last !== undefined) {
      this.heap[0] = last;
      this.siftDown(0);
    }
    return top;
  }

  /** Drop pending events of one kind for one node (e.g. a node goes offline). */
  cancel(kind: EventKind, nodeId: string): void {
    const kept = this.heap.filter((e) => !(e.kind === kind && e.nodeId === nodeId));
    this.heap = kept;
    for (let i = (this.heap.length >> 1) - 1; i >= 0; i--) this.siftDown(i);
  }

  private less(a: SimEvent, b: SimEvent): boolean {
    if (a.at !== b.at) return a.at < b.at;
    return a.seq < b.seq;
  }

  private siftUp(i: number): void {
    while (i > 0) {
      const parent = (i - 1) >> 1;
      if (this.less(this.heap[i], this.heap[parent])) {
        const tmp = this.heap[i];
        this.heap[i] = this.heap[parent];
        this.heap[parent] = tmp;
        i = parent;
      } else {
        break;
      }
    }
  }

  private siftDown(i: number): void {
    const n = this.heap.length;
    for (;;) {
      const l = i * 2 + 1;
      const r = l + 1;
      let smallest = i;
      if (l < n && this.less(this.heap[l], this.heap[smallest])) smallest = l;
      if (r < n && this.less(this.heap[r], this.heap[smallest])) smallest = r;
      if (smallest === i) break;
      const tmp = this.heap[i];
      this.heap[i] = this.heap[smallest];
      this.heap[smallest] = tmp;
      i = smallest;
    }
  }
}
