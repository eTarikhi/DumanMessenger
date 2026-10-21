# Skill 06 — Persistence & Sync (CRDT)

**Goal:** History survives kills/partitions and converges without server.

### Storage
- `drift` SQLite: tables `messages, peers, groups, queueOpp, seenCache, ogmTable`
- Optional `sqlcipher` for at-rest encryption (key in keystore)
- SeenCache: LRU 5000 msgIds, 5 min window for dedup

### Beacon
- BLE advert payload: `8B dbHash + 4B nodePrefix` (Meshenger pattern [1](https://github.com/ebregger/Meshenger))
- If peer’s hash != mine → anti-entropy sync: exchange missing rowIds via GATT, then patch

### CRDT (Group/Broadcast)
- Each message is an **add-only row** (no edits) with `lamportTs + nodeId` → deterministic order
- Merge = union; no conflicts (chat is append-only). Deletions are tombstones (optional)
- Sync protocol: `SYNC_REQ {sinceHash}` → `SYNC_RESP {rows}`

### Do / Don't
- DO bound DB: auto-trim >10k msgs per chat (archive prompt)
- DO gossip hash every 5s when connected to peer
- DON'T sync full DB on every beacon — only delta

### Acceptance
- [ ] Kill app mid-sync, reopen → no duplication, history intact
- [ ] A writes 10 msgs offline, B writes 10 offline, they meet → both end with 20 in same order
- [ ] Airplane→reconnect sync <2s for 100-msg delta
