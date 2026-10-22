/// Deterministic discrete-event queue, mirroring `src/events.ts`.
///
/// The mesh is simulated as events on a virtual clock rather than as one
/// synchronous recursive burst. That is what makes latency, the MPR 300 ms wait
/// and the TTL/expiry windows meaningful (docs/02 §6 "text delivery < 2 s 1 hop").
///
/// Ordering is total: events compare by (at, seq), so equal-timestamp events run
/// in insertion order and both language engines agree exactly.
library;

enum EventKind {
  physics,
  ogm,
  election,
  scan,
  msg,
  mpr,
  ackTimeout,

  /// Repeat an SOS flood (docs/05: "SOS mode: repeated flood of GPS + text").
  sosRepeat,

  /// Put one push-to-talk frame on air at its capture time (docs/05 §3.3).
  transferChunk,

  /// Re-send whatever a stalled transfer is still missing (docs/05 §3.2 "resume").
  transferStall,

  /// Offer this node's group-history digests to its peers (anti-entropy).
  historyBeacon,
  traffic
}

class SimEvent {
  SimEvent(this.at, this.seq, this.kind, this.nodeId, [this.payload]);

  final double at;
  final int seq;
  final EventKind kind;
  final String nodeId;
  Object? payload;
}

class EventQueue {
  final List<SimEvent> _heap = <SimEvent>[];
  int _seqCounter = 0;

  int get length => _heap.length;

  bool get isEmpty => _heap.isEmpty;

  void clear() {
    _heap.clear();
    _seqCounter = 0;
  }

  void push(double at, EventKind kind, String nodeId, [Object? payload]) {
    _heap.add(SimEvent(at, _seqCounter++, kind, nodeId, payload));
    _siftUp(_heap.length - 1);
  }

  SimEvent? peek() => _heap.isEmpty ? null : _heap.first;

  SimEvent? pop() {
    if (_heap.isEmpty) return null;
    final top = _heap.first;
    final last = _heap.removeLast();
    if (_heap.isNotEmpty) {
      _heap[0] = last;
      _siftDown(0);
    }
    return top;
  }

  /// Drop pending events of one kind for one node (e.g. a node goes offline).
  void cancel(EventKind kind, String nodeId) {
    _heap.removeWhere((e) => e.kind == kind && e.nodeId == nodeId);
    for (var i = (_heap.length >> 1) - 1; i >= 0; i--) {
      _siftDown(i);
    }
  }

  bool _less(SimEvent a, SimEvent b) {
    if (a.at != b.at) return a.at < b.at;
    return a.seq < b.seq;
  }

  void _siftUp(int i) {
    while (i > 0) {
      final parent = (i - 1) >> 1;
      if (_less(_heap[i], _heap[parent])) {
        final tmp = _heap[i];
        _heap[i] = _heap[parent];
        _heap[parent] = tmp;
        i = parent;
      } else {
        break;
      }
    }
  }

  void _siftDown(int i) {
    final n = _heap.length;
    while (true) {
      final l = i * 2 + 1;
      final r = l + 1;
      var smallest = i;
      if (l < n && _less(_heap[l], _heap[smallest])) smallest = l;
      if (r < n && _less(_heap[r], _heap[smallest])) smallest = r;
      if (smallest == i) break;
      final tmp = _heap[i];
      _heap[i] = _heap[smallest];
      _heap[smallest] = tmp;
      i = smallest;
    }
  }
}
