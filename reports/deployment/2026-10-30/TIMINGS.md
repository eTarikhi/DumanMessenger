# Individual paired timings

V8 CPU profiling enabled in both runs; unchanged5000ms. Original11 plus one additional
local marginal timeout (observed-maximum normalisation). Profiling adds overhead; these
are not unprofiled CI timings or a statistical performance guarantee. No original test
body/assertion/input was edited, split or moved into fixtures.

| Test (exact name) | Before ms | After ms | After |
|---|---:|---:|---|
| dense crowd (docs/02 §6: 50+ nodes) stays stable and cheap at 60 nodes | 23610.9 | 19996.0 | failed |
| dense crowd (docs/02 §6: 50+ nodes) holds its delivery bar on seeds the gate above does not use | 63270.5 | 52737.5 | failed |
| dense crowd (docs/02 §6: 50+ nodes) costs MPR nothing against the same engine without suppression | 66733.9 | 57647.9 | failed |
| the density-derived beacon interval (docs/06 §24.11) holds the topology still, and there the derived interval is cheaper without losing reach | 6927.9 | 4465.7 | passed |
| radioOccupancy costs a dense crowd fewer deferrals and buys it delivery, once contention is modelled | 7310.0 | 6938.2 | failed |
| adaptive scan intervals (docs/05 §1.2, layer 3) scans more in a dense world, which is what the row says and what it costs | 9636.9 | 7748.3 | failed |
| adaptive scan intervals (docs/05 §1.2, layer 3) clamps, so one peer does not stop a node scanning and a crowd does not pin it awake | 9390.4 | 7224.7 | failed |
| protocol behaviour scale: the documented 10-200 node range (skills/08) runs at the top of the range, and the fallback does not go quadratic | 15532.5 | 15034.3 | failed |
| community relays (roadmap Phase 5: a plugged tablet in a café) elects the plugged tablets and moves relay work off other people's batteries | 17372.9 | 15223.2 | failed |
| cap-aware community-relay promotion, measured and rejected (docs/06 §19.4) exempting tablets from the cap elects all six and pushes the ratio to the top of the band | 8533.1 | 6588.8 | failed |
| observed-maximum peer normalisation, measured and rejected (docs/06 §18.4) holds skills/02's band on the campus world, and puts one seed on its floor | 5570.1 | 3944.4 | passed |
| preferring a community relay, measured and rejected (docs/06 §19.5) and that is where the benefit stops: the bundle waits on a node that never moves | 9385.5 | 8021.4 | failed |
