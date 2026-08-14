# Positioning — what agent-mesh is, and what it is not

One page on where this product sits relative to the existing multi-agent
landscape: what is genuinely unusual about it, what is a re-implementation of a
known pattern, and which problem it is the right tool for.

## 1. The one-line framing

**GitOps for agent coordination.** GitOps made a git repo the single source of
truth that distributed nodes reconcile against, for deployments. This product
does the same thing for agent work: the bus repo is the ledger, and nodes
converge on it by `pull` and `push`. No broker, no server, no inbound ports.

## 2. The constraint that defines the product

Every mainstream framework assumes agents can reach each other, or can reach a
common broker. This product assumes the opposite: **nodes that cannot open
connections to one another** — HPC login nodes, machines behind NAT, hosts on
networks the operator does not control and cannot add infrastructure to.

That single constraint produces the rest of the design:

| Constraint | Consequence |
|---|---|
| No inbound connectivity | Transport is outbound-only git; a hosted remote is the only shared component |
| No standing infrastructure to run | Git's push serialization replaces a lock service |
| Nodes disconnect and return | Append-only messages + mutable single-writer state; a reconnecting node rebases cleanly |
| No coordinator process | Role addressing + accept-as-claim; the first push wins and losers yield |
| Hosted-git rate limits | Liveness by ACK, not heartbeat; an idle node only pulls |

## 3. What is genuinely uncommon

- **Git as the message bus itself**, not as config storage beside a bus. The
  ledger, the queues, the claim mechanism, and the durable library are all one
  repo's history.
- **Merge conflicts eliminated by construction** rather than resolved. The
  single-writer table (`spec/PROTOCOL.md` §3.1) is what makes an uncoordinated
  multi-writer repo safe without locking.
- **Zero-cost idle.** Repo traffic and token spend are proportional to real
  work, not to node count × poll frequency × uptime — a parked scanner and no
  idle-node writes.
- **The curated library as a first-class plane.** Durable knowledge is a
  librarian-curated, self-describing record set with retention policy, not an
  agent memory buffer.

None of these is individually novel. The combination — durable, conflict-free,
NAT-traversing multi-host coordination with no standing infrastructure — has no
close competitor.

## 4. Neighbors, and how they differ

**Orchestration frameworks** (LangGraph, CrewAI, AutoGen/AG2, Google ADK, OpenAI
Agents SDK). The crowded space, and architecturally opposite. They coordinate
richly-connected agents through a graph, message pool, or checkpointer, usually
under one orchestrator process. They solve planning and state-passing well; they
do not address unreachable hosts, and would need a reachable broker to try. This
product refuses a broker on purpose.

**Interoperability protocols** (A2A, MCP, ACP). Adjacent layer, not a
substitute. A2A standardizes discovery and task delegation between agents but
assumes an agent can open a connection to another agent; this protocol covers
similar ground — role addressing, task lifecycle, terminal status — without that
assumption. MCP is tool and context access, orthogonal and complementary: mesh
agents can use MCP for tools while coordinating over the bus.

**GitOps and git-as-a-database** (ArgoCD, Flux; Dolt and friends). The closest
ancestors in spirit. Same instinct — git's replication and history are the
durability layer — applied to deployments and data rather than to agent work.

**Classic distributed-systems patterns.** Two are re-implemented here on git
instead of on dedicated infrastructure: accept-as-claim is leader election over
a single task (git's push serialization in place of a consensus store), and role
queues are competing consumers (durable by default, and pollable from behind a
firewall).

## 5. When to choose something else

Honest boundaries, so the fit is obvious:

- **Agents in one datacenter or one process.** Use an orchestration framework.
  A git round-trip per transition is latency you do not need to pay.
- **Sub-second coordination.** The floor here is a poll interval and a push;
  this is a minutes-scale substrate, not a real-time one.
- **A deterministic tool pipeline.** If the call order is known, no agent-to-agent
  coordination layer is warranted at all.
- **High-frequency chatter between agents.** The design assumes traffic
  proportional to real work. A conversational inner loop between two agents
  belongs in one process.

The remote is the one component whose loss halts the mesh
(`spec/PROTOCOL.md` §11) — an accepted, stated trade for having no other
infrastructure at all.

## 6. The fit, stated plainly

Multi-host agent work where the hosts are ones you do not control, cannot open
ports on, and cannot install a broker beside — and where the work is durable and
minutes-scale rather than conversational. That niche is real, and the named
frameworks do not serve it.
