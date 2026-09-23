---------------------------- MODULE Replication ----------------------------
(***************************************************************************)
(* Leader based replication, in-sync replicas (ISR) and failover as in     *)
(* src/lavinmq/clustering (Server, Follower, Client, Controller) and       *)
(* src/lavinmq/persister.cr.                                               *)
(*                                                                         *)
(* A node's data is one append-only segment, modelled as the set of       *)
(* messages it holds durably. Two segments are equal, and so hash equal,   *)
(* exactly when they hold the same messages.                               *)
(*                                                                         *)
(* etcd is modelled as the variables leader, candidates and isr. Only the  *)
(* current leader writes isr (put_if_election_leader fences the others).   *)
(* A leader losing its lease is modelled as the leader crashing.           *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS
    Nodes,
    Msgs,
    NoNode,
    NoSnap,
    SyncAck,       \* protocol 1.1: a follower joins the ISR once it acks its full sync
    FlushIsrOnSync \* the leader commits the ISR without a follower before syncing it

VARIABLES
    alive,        \* nodes whose process is running
    leader,       \* etcd election winner, or NoNode
    candidates,   \* etcd election queue, oldest candidacy first
    campaigned,   \* node has queued a candidacy in this process lifetime
    isr,          \* etcd ISR key
    disk,         \* durable segment content per node
    link,         \* follower state on the leader: "none", "syncing", "synced"
    snap,         \* full sync sent by the leader, not yet written by the follower
    inSync,       \* Follower#in_sync?: the leader got the follower's sync ack
    inflight,     \* streamed appends sent, not yet written and acked
    dirty,        \* Server @dirty_isr
    published,    \* ever written by a leader, so each message is published once
    written,      \* written locally by the current leader, not yet dispatched
    dispatched,   \* dispatched by the current leader, confirm pending
    confirmed     \* publish confirms sent to clients

followerVars == <<link, snap, inSync, inflight>>
msgVars == <<published, written, dispatched, confirmed>>
vars == <<alive, leader, candidates, campaigned, isr, disk, dirty,
          followerVars, msgVars>>

Remove(s, n) == SelectSeq(s, LAMBDA x : x /= n)
Synced == {f \in Nodes : link[f] = "synced"}

(* Synced followers the ISR may list: with SyncAck only once they have    *)
(* acked their full sync.                                                 *)
IsrFollowers == IF SyncAck THEN Synced \cap inSync ELSE Synced

(* Server#update_isr *)
IsrNow == {leader} \cup IsrFollowers

NoLinks ==
    /\ link' = [n \in Nodes |-> "none"]
    /\ snap' = [n \in Nodes |-> NoSnap]
    /\ inSync' = {}
    /\ inflight' = [n \in Nodes |-> {}]

DropLink(f) ==
    /\ link' = [link EXCEPT ![f] = "none"]
    /\ snap' = [snap EXCEPT ![f] = NoSnap]
    /\ inSync' = inSync \ {f}
    /\ inflight' = [inflight EXCEPT ![f] = {}]

Init ==
    /\ alive = Nodes
    /\ leader = NoNode
    /\ candidates = <<>>
    /\ campaigned = [n \in Nodes |-> FALSE]
    /\ isr = Nodes \* a fresh cluster: every node starts empty and equal
    /\ disk = [n \in Nodes |-> {}]
    /\ link = [n \in Nodes |-> "none"]
    /\ snap = [n \in Nodes |-> NoSnap]
    /\ inSync = {}
    /\ inflight = [n \in Nodes |-> {}]
    /\ dirty = FALSE
    /\ published = {}
    /\ written = {}
    /\ dispatched = {}
    /\ confirmed = {}

(* Controller#run: wait_to_be_insync, then campaign once per process. *)
Campaign(n) ==
    /\ n \in alive
    /\ ~campaigned[n]
    /\ n \in isr
    /\ candidates' = Append(candidates, n)
    /\ campaigned' = [campaigned EXCEPT ![n] = TRUE]
    /\ UNCHANGED <<alive, leader, isr, disk, dirty, followerVars, msgVars>>

(* The oldest candidacy wins. Controller#ensure_in_isr! makes a winner    *)
(* outside the ISR exit instead. A new Server starts with @dirty_isr.     *)
Elect ==
    /\ leader = NoNode
    /\ candidates /= <<>>
    /\ candidates' = Tail(candidates)
    /\ LET w == Head(candidates) IN
        IF w \in isr
        THEN /\ leader' = w
             /\ dirty' = TRUE
             /\ UNCHANGED alive
        ELSE /\ alive' = alive \ {w}
             /\ UNCHANGED <<leader, dirty>>
    /\ NoLinks
    /\ UNCHANGED <<campaigned, isr, disk, msgVars>>

(* MessageStore#push writes locally first. *)
Write(m) ==
    /\ leader /= NoNode
    /\ m \notin published
    /\ published' = published \cup {m}
    /\ written' = written \cup {m}
    /\ disk' = [disk EXCEPT ![leader] = @ \cup {m}]
    /\ UNCHANGED <<alive, leader, candidates, campaigned, isr, dirty,
                   followerVars, dispatched, confirmed>>

(* Server#each_follower then streams it to synced followers only (a       *)
(* syncing follower gets it through its full sync) and flushes a dirty    *)
(* ISR before returning.                                                  *)
Dispatch(m) ==
    /\ m \in written
    /\ written' = written \ {m}
    /\ dispatched' = dispatched \cup {m}
    /\ inflight' = [f \in Nodes |->
                      IF f \in Synced THEN inflight[f] \cup {m} ELSE inflight[f]]
    /\ IF dirty
       THEN /\ isr' = IsrNow
            /\ dirty' = FALSE
       ELSE UNCHANGED <<isr, dirty>>
    /\ UNCHANGED <<alive, leader, candidates, campaigned, disk, link, snap,
                   inSync, published, confirmed>>

(* Persister#drain_pending_acks: syncfs, then Server#wait_for_followers  *)
(* waits for every synced follower to ack all sent bytes and flushes a   *)
(* dirty ISR before the confirm goes out.                                *)
Confirm(m) ==
    /\ m \in dispatched
    /\ ~dirty
    /\ \A f \in Synced : inflight[f] = {}
    /\ dispatched' = dispatched \ {m}
    /\ confirmed' = confirmed \cup {m}
    /\ UNCHANGED <<alive, leader, candidates, campaigned, isr, disk, dirty,
                   followerVars, published, written>>

(* Server#flush_isr, also reached through the lazy paths above. *)
FlushIsr ==
    /\ leader /= NoNode
    /\ dirty
    /\ isr' = IsrNow
    /\ dirty' = FALSE
    /\ UNCHANGED <<alive, leader, candidates, campaigned, disk, followerVars,
                   msgVars>>

(* Client#sync_files deletes a file whose hash differs from the leader's *)
(* before requesting it again. With FlushIsrOnSync Server#sync_and_serve  *)
(* first commits the ISR without the follower.                           *)
StartSync(f) ==
    /\ leader /= NoNode
    /\ f \in alive \ {leader}
    /\ link[f] = "none"
    /\ link' = [link EXCEPT ![f] = "syncing"]
    /\ disk' = IF disk[f] = disk[leader] THEN disk
               ELSE [disk EXCEPT ![f] = {}]
    /\ IF FlushIsrOnSync
       THEN /\ isr' = {leader} \cup (IsrFollowers \ {f})
            /\ dirty' = FALSE
       ELSE UNCHANGED <<isr, dirty>>
    /\ UNCHANGED <<alive, leader, candidates, campaigned, snap, inSync,
                   inflight, msgVars>>

(* Server#sync_and_serve: the last full_sync is sent, then mark_synced!.   *)
(* Without SyncAck update_isr follows at once, before the follower has   *)
(* written the sync.                                                     *)
FinishSync(f) ==
    /\ link[f] = "syncing"
    /\ snap' = [snap EXCEPT ![f] = disk[leader]]
    /\ link' = [link EXCEPT ![f] = "synced"]
    /\ IF SyncAck
       THEN UNCHANGED <<isr, dirty>>
       ELSE /\ isr' = {leader} \cup Synced \cup {f}
            /\ dirty' = FALSE
    /\ UNCHANGED <<alive, leader, candidates, campaigned, disk, inSync,
                   inflight, msgVars>>

(* The follower writes and syncs the received files, then acks the sync. *)
ApplySync(f) ==
    /\ snap[f] /= NoSnap
    /\ disk' = [disk EXCEPT ![f] = snap[f]]
    /\ snap' = [snap EXCEPT ![f] = NoSnap]
    /\ UNCHANGED <<alive, leader, candidates, campaigned, isr, dirty, link,
                   inSync, inflight, msgVars>>

(* Follower#wait_for_sync_ack returns, then update_isr lists the follower. *)
JoinIsr(f) ==
    /\ SyncAck
    /\ f \in Synced \ inSync
    /\ snap[f] = NoSnap
    /\ inSync' = inSync \cup {f}
    /\ isr' = {leader} \cup (Synced \cap inSync')
    /\ dirty' = FALSE
    /\ UNCHANGED <<alive, leader, candidates, campaigned, disk, link, snap,
                   inflight, msgVars>>

(* Client#stream_changes: write, syncfs, ack. Streamed after the sync. *)
Apply(f, m) ==
    /\ snap[f] = NoSnap
    /\ m \in inflight[f]
    /\ disk' = [disk EXCEPT ![f] = @ \cup {m}]
    /\ inflight' = [inflight EXCEPT ![f] = @ \ {m}]
    /\ UNCHANGED <<alive, leader, candidates, campaigned, isr, dirty, link,
                   snap, inSync, msgVars>>

(* Connection loss. A follower behind leaves the ISR at once, a caught-up *)
(* one stays listed until the dirty ISR is flushed.                      *)
Disconnect(f) ==
    /\ link[f] /= "none"
    /\ DropLink(f)
    /\ IF link[f] = "synced" /\ inflight[f] /= {}
       THEN /\ isr' = {leader} \cup (IsrFollowers \ {f})
            /\ dirty' = FALSE
       ELSE /\ dirty' = (dirty \/ link[f] = "synced")
            /\ UNCHANGED isr
    /\ UNCHANGED <<alive, leader, candidates, campaigned, disk, msgVars>>

(* Crash, or lease loss for a leader: its candidacy goes with the lease, *)
(* and so do its pending writes and confirms.                            *)
Crash(n) ==
    /\ n \in alive
    /\ alive' = alive \ {n}
    /\ candidates' = Remove(candidates, n)
    /\ IF n = leader
       THEN /\ leader' = NoNode
            /\ NoLinks
            /\ written' = {}
            /\ dispatched' = {}
            /\ UNCHANGED dirty
       ELSE /\ DropLink(n)
            /\ dirty' = (dirty \/ link[n] = "synced")
            /\ UNCHANGED <<leader, written, dispatched>>
    /\ UNCHANGED <<campaigned, isr, disk, published, confirmed>>

Restart(n) ==
    /\ n \notin alive
    /\ alive' = alive \cup {n}
    /\ campaigned' = [campaigned EXCEPT ![n] = FALSE]
    /\ UNCHANGED <<leader, candidates, isr, disk, dirty, followerVars, msgVars>>

Next ==
    \/ Elect
    \/ FlushIsr
    \/ \E m \in Msgs : Write(m) \/ Dispatch(m) \/ Confirm(m)
    \/ \E n \in Nodes :
        \/ Campaign(n) \/ StartSync(n) \/ FinishSync(n) \/ ApplySync(n)
        \/ JoinIsr(n) \/ Disconnect(n) \/ Crash(n) \/ Restart(n)
        \/ \E m \in Msgs : Apply(n, m)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
TypeOK ==
    /\ alive \subseteq Nodes
    /\ leader \in Nodes \cup {NoNode}
    /\ isr \subseteq Nodes
    /\ inSync \subseteq Nodes
    /\ \A n \in Nodes : disk[n] \subseteq Msgs
    /\ confirmed \subseteq published

(* What a publisher relies on: the serving leader has every confirmed message. *)
LeaderHasConfirmed == leader /= NoNode => confirmed \subseteq disk[leader]

(* Sanity: a confirm can happen at all, so the model isn't vacuously safe. *)
NeverConfirms == confirmed = {}
=============================================================================
