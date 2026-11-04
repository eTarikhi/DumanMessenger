# Structured networking review — checked2026-10-29

Evidence levels: **P** published/standard/source finding; **I** project-specific inference;
**H** unverified local hypothesis. Search snippets/abstracts and the explicitly retrieved
RFC pages/implementation are the evidence boundary: no claim to have reproduced the
papers' experiments or audited every full paper. The online tools could retrieve external
metadata/RFCs; shell egress is restricted to GitHub/npm/PyPI hosts. Local Dart unavailable.

## Bibliographic verification and status

- Clausen, Dearlove, Jacquet, Herberg, RFC7181, *The Optimized Link State Routing Protocol
Version2*, April2014: RFC Editor currently labels **Proposed Standard**, updated by7183,
7187,7188,7466 (retrieved https://www.rfc-editor.org/info/rfc7181/). Not an obsolete
Internet-Draft. Directional/additive metrics are distinct from hop-only MPR coverage;
no automatic mapping from their link database to Duman's truncated advertisements.
- Lindgren, Doria, Davies, Grasic, RFC6693, *Probabilistic Routing Protocol for
Intermittently Connected Networks*, August2012: **Experimental**, not Standards Track
(retrieved https://www.rfc-editor.org/info/rfc6693/). Encounter-history/transitivity and
queue policies address temporal connectivity, not a guarantee of short-hop delivery.
- De Couto, Aguayo, Bicket, Morris, *A High-Throughput Path Metric for Multi-Hop Wireless
Routing*, MobiCom September2003. Author/title/date corroborated by academic bibliography
[2](http://www.cs.cmu.edu/~dga/15-849/papers/decouto-etx2003-abstract.html).
User's MIT repository URL was not independently retrieved; no quotation attributed to it.
- Draves, Padhye, Zill, *Comparison of routing metrics for static multi-hop wireless
networks*, SIGCOMM2004, publisher date30August2004. Physical testbed: ETX best stationary,
but hop count beats quality metrics in the mobile-sender case; RTT/packet-pair probing
can suffer self-interference [3](https://dl.acm.org/doi/10.1145/1030194.1015483).
- Draves, Padhye, Zill, *Routing in multi-radio, multi-hop wireless mesh networks*,2004:
stationary multiradio testbed, ETT/WCETT channel diversity. Reported86% median throughput
improvement with two radios versus single-radio baseline is NOT a packet delivery or
mobile-phone result [1](https://pages.cs.wisc.edu/~suman/courses/740/papers/multiradio-mobicom04.pdf).
- Hsu, Liu, Seah, *Opportunistic routing – A review and the challenges ahead*, Computer
Networks55(15),3592–3603, issue27October2011, DOI10.1016/j.comnet.2011.06.021. Publisher
metadata confirms authors/title [1](https://www.sciencedirect.com/science/article/abs/pii/S1389128611002337).
Author manuscript describes candidate coordination and batch/coding trade-offs
[3](https://homepages.ecs.vuw.ac.nz/~winston/papers/COMNET-Opportunistic_Routing_final.pdf).
- Spyropoulos, Psounis, Raghavendra, *Spray and wait: an efficient routing scheme for
intermittently connected mobile networks*, WDTN2005, DOI10.1145/1080139.1080143. Metadata
verified; bounded-copy DTN, not an on-device five-hop demonstration
[1](https://www.semanticscholar.org/paper/Spray-and-wait:-an-efficient-routing-scheme-for-Spyropoulos-Psounis/44ecb60efb44bd83e256c7a7e0f6b4e3825a18d2).
- Radunovic, Gkantsidis, Key, Rodriguez, Hu, *An optimization framework for practical
multipath routing in wireless mesh networks*, MSR-TR-2007-81, **June2007**. Publisher
abstract reports primal-dual joint scheduling/routing/coding, simulation20–200% throughput
benefit versus single-path; random rather than optimal scheduling for decentralized
implementation [1](https://www.microsoft.com/en-us/research/publication/an-optimization-framework-for-practical-multipath-routing-in-wireless-mesh-networks/).
This technical report is not the separately titled2008 INFOCOM paper.
- Ni, Lan, Malaney, *On the performance of expected transmission count (ETX) for wireless
mesh networks*: DOI containsVALUETOOLS2008, but publisher lists MODENETS and publication
**16May2010**. Do not silently cite2008 as verified publication date. Abstract/metadata
retrieved, detailed performance claims not used [2](https://eudl.eu/doi/10.4108/ICST.VALUETOOLS2008.4588).
- Amir, Naeem, Ali, Gulzar, *MultiObjective Optimization in Wireless Mesh Networks –
A Survey*, DOI10.1145/3800685: publisher published27April2026, online accepted manuscript
19March2026, CSUR58(11), August2026. Thus not a future/unverified preprint on this session
date [2](https://dl.acm.org/doi/10.1145/3800685). Scope is survey, not an implementation
proving any Duman improvement. Third-party search page mixes unrelated abstracts; those
snippets were not treated as results of this survey.

## Mechanism/applicability matrix

Costs below are engineering estimates (**I**), not paper measurements or owner budgets.
Each row's experiment is **H**, unless explicitly run in the current results report.

| Problem | Published technique | Evidence/source | Assumptions | Benefits | Failure modes/trade-offs | Applicability here | Implementation cost | Local experiment needed |
|---|---|---|---|---|---|---|---|---|
| Lossy short paths | ETX, expected bidirectional attempts1/(df*dr); ETT adds packet size/rate | De Couto2003; Draves2004 above | Measured forward/reverse loss, comparable probes, stationary enough windows | Prefer reliable links rather than arbitrary hop minimum | Probe/data mismatch; asymmetric ACK; a longer reliable path can miss five-hop objective; load not captured | Existing TQ is originator/neighbor OGM history, NOT end-to-end ETX. Need per-link unicast/ACK telemetry | Medium/high, wire semantics+Dart | Compare hop-budget-constrained cost against baseline/epoch, under mobility and asymmetric loss; don't call TQ reciprocal full ETX |
| Unstable metrics | Hysteresis, age validity, MRHOF | Contiki-NG rpl-mrhof.c source below; OLSRv2 validity | Fresh local measurements; root-oriented RPL differs from peer mesh | Avoid flapping; reject old routes | Slow response to genuine movement; first fresh path can be worse | Epoch-only local experiment already failed robust delivery. Never transplant rank/root assumptions | Medium | Age-aware competing next hops, bounded hysteresis; separate age and cost ablations |
| Congestion/relay unfairness | Primal-dual utility/load-aware multipath | MSR-TR-2007-81 above, simulation | Queue feedback, radio scheduling, utility fairness | Joint rate/path allocation rather than equal splitting | Coupled interference; correlated cut vertices; control overhead; unstable pressure loops | Default free/none model lacks contention; global queue oracle forbidden | High | Queue occupancy/sender load distribution first, then queued-radio sensitivity and shared-cut stress. No claimed capacity optimality |
| Loss/next-hop diversity | ExOR candidate coordination; MORE coding | Hsu review/manuscript above | Broadcast reception coordination, batches/coding, Wi-Fi MAC | Use actual receiving candidates, spatial diversity | Duplicate airtime, batch latency, shared bottlenecks; not independent path probabilities | Short text messages poorly fit10–100 packet batches; select one bounded extra first hop as a diagnostic alternative, not ExOR implementation | Low for bounded source alternative; high for coding | Source first-hop backup1 copy vs no backup, unchanged downstream duplicate suppression; quantify reconvergence unknown and load |
| Intermittent connectivity | PRoPHET encounter predictability/transitivity | RFC6693 Experimental above | Repeated useful contacts, learned history | Forward toward likely future contacts | Cold start, obsolete routines, storage/control; no contact means no delivery | Community/SUPER preference already negative; need actual contact history | High | Contact feasibility bounds first; store-carry-forward only where feasible and enough horizon remains |
| Replica explosion | Spray-and-Wait bounded copies | Spyropoulos2005 above | Copy budget and waiting contacts | Restrict epidemic overhead | Delay, correlated carriers, copy budget can miss important future encounters | Existing DTN spray3 is not identical algorithm and retry hops reset; don't conflate eventual and<=5 | Medium | Compare contact-aware carrier with same copy/expiry bound; no increase until budget approved |
| Dense broadcast | OLSRv2 MPR, Trickle redundancy | RFC7181 above; Levis et al. RFC6206, March2011 Standards Track [4](https://tools.ietf.org/html/rfc6206) | Coverage/consistency observations are timely and meaningful | Suppress redundant transmissions | Stale/truncated views, suppression correlated with loss | Prior MPR-disable+151% relay and−0.22pp warns against blanket removal | Medium | Age-limited coverage proof or one targeted repair, not unrestricted flooding |
| Retry/ACK ambiguity | SRTT/RTTVAR, Karn's sampling | Paxson, Allman, Chu, Sargent RFC6298, June2011 [1](http://www.hjp.at/doc/rfc/rfc6298.html) | TCP-specific acknowledgments and RTT identity | Avoid too-early timeout and ambiguous samples | DTN RTT heavy-tail, queue wait, retransmission identity | Learn per-attempt on-air timing; do not copy TCP minimumRTO as mesh optimum | Medium | Separate queue residence, path transit, retry timing; matched factorial only if demonstrated interaction |
| Receiver sleep/discovery | Phase-lock and repeated wakeup packets | Dunkels2011 *The ContikiMAC Radio Duty Cycling Protocol*, SICS T2011:13; author bibliography [3](https://dunkels.com/adam/publications-bib.html) | Radio transceiver truly sleeps; measured sensor hardware | Reduced radio-on fraction via wake alignment | Repeated transmissions, phase drift | Duman sleep currently scanner-off, not RX-off. Its battery estimate cannot validate ContikiMAC | High/native adapter | Actual receiver-off model/hardware wake latency before importing timing conclusions |
| Adaptive learning | Q-routing distributed delay updates | Boyan/Littman1993 NeurIPS [1](https://proceedings.neurips.cc/paper_files/paper/1993/file/4ea06fbc83cdd0a06020c35d50e1e89a-Paper.pdf) | Repeated observations, feedback, simulated switching network | Local delay adaptation | Nonstationarity, exploration losses, delayed/absent reward | No approved superior action library; sparse failures weak feedback | High | Diagnostic supervised error analysis first; no RL online exploration justified |
| Lightweight selector | LinUCB confidence/reward model | Li/Chu/Langford/Schapire2010 WWW [1](https://www.cs.utexas.edu/~shivaram/readings/b2hd-LiCLS2010.html) | Linear reward structure, observed outcomes | Small/local inference versus deep policy | Network actions coupled, censored feedback, context shift | News recommendation evidence is not mesh performance proof | Medium | Fit only approved bounded actions after counterfactual paired data; current failure model cannot estimate policy benefit |
| Competing objectives | Pareto constraints, evolutionary/Bayesian/hybrid search | Amir et al. survey above; prior local studies | Reproducible expensive objectives, explicit budgets | Expose reliability/resource trade-offs | Search overfit, sample costs, reward trade-offs can hide protected regressions | Use finite deterministic hypotheses and Pareto audit first; Gaussian-process BO/RL unnecessary for one binary treatment | Low for Pareto; high for deep RL | Freeze gates before unseen seeds; report negative points/dominated arms; no weighted reward replacing acceptance |

## Reproducible implementation inspection

Read GitHub `contiki-ng/contiki-ng/os/net/routing/rpl-lite/rpl-mrhof.c` via API, including
ETX versus squared-ETX discussion, maximum link/path cost and parent-switch hysteresis.
Source URL: https://github.com/contiki-ng/contiki-ng/blob/develop/os/net/routing/rpl-lite/rpl-mrhof.c
Current file commit is separately retained in research-source.json (do not assume develop
will remain identical). Code explicitly warns that penalizing weak links can cause more
switches/loops/Trickle resets. This is implementation evidence of a trade-off, not a
benchmark of Duman. No imported dependency or copied source code was needed.

## Ranked local hypotheses (inference, not published conclusions)

1. Limited alternative first hop can escape a bad primary without suppressing MPR or
replicating every relay. Existing reverse-route/over-budget events justify a bounded
experiment, NOT a claim of node-disjoint multipath. A different neighbor can converge on
the same cut vertex. Use only locally advertised bestHopTo/TQ, not another node's live
routing table, physical location or future contact oracle.
2. Coverage-age checking is plausible, but a reliable direct-beacon timestamp/neighbor
list lifetime is not currently retained. No lastSeen surrogate can silently be called
list age. Defer wire/state change rather than invent measurements.
3. Queue-aware cost/ETX need missing directional/queue telemetry and a realistic radio
profile. Investigate with proxies and counter-model sensitivity; defer an optimizer.
4. Failure-model analysis can expose limited predictive information and horizon effects;
it cannot manufacture a good strategy or prove causal leverage. Learned deployment is
blocked unless simpler interventions actually win and have Dart parity.
