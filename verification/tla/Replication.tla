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
(* etcd is modelled as the variables etcdLeader, candidates and isr. Only  *)
(* the node holding the leader key writes isr (put_if_election_leader      *)
(* fences the others). With LeaseExpiry a leader can lose its lease while  *)
(* it still serves, until it notices (Etcd::Lease#keepalive_loop), so two  *)
(* nodes may serve at once.                                                *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS
    Nodes,
    Msgs,
    NoNode,
    NoSnap,
    SyncAck,        \* protocol 1.1: a follower joins the ISR once it acks its full sync
    FlushIsrOnSync, \* the leader commits the ISR without a follower before syncing it
    LeaseExpiry     \* a leader's lease can expire in etcd before the leader notices

VARIABLES
    alive,        \* nodes whose process is running
    serving,      \* nodes acting as leader, Server running
    etcdLeader,   \* node holding the etcd leader key, or NoNode
    candidates,   \* etcd election queue, oldest candidacy first
    campaigned,   \* node has queued a candidacy in this process lifetime
    isr,          \* etcd ISR key
    disk,         \* durable segment content per node
    following,    \* leader a node replicates from (its Client), or NoNode
    link,         \* follower state on the leader it follows: "none", "syncing", "synced"
    snap,         \* full sync sent by the leader, not yet written by the follower
    inSync,       \* Follower#in_sync?: the leader got the follower's sync ack
    inflight,     \* streamed appends sent, not yet written and acked
    dirty,        \* Server @dirty_isr, per serving node
    published,    \* ever written by a leader, so each message is published once
    written,      \* per leader: written locally, not yet dispatched
    dispatched,   \* per leader: dispatched, confirm pending
    confirmed     \* publish confirms sent to clients

etcdVars == <<etcdLeader, candidates, campaigned, isr>>
followerVars == <<following, link, snap, inSync, inflight>>
msgVars == <<published, written, dispatched, confirmed>>
vars == <<alive, serving, disk, dirty, etcdVars, followerVars, msgVars>>

Remove(s, n) == SelectSeq(s, LAMBDA x : x /= n)

(* Followers streaming from leader l *)
Synced(l) == {f \in Nodes : following[f] = l /\ link[f] = "synced"}

(* Synced followers the ISR may list: with SyncAck only once they have    *)
(* acked their full sync.                                                 *)
IsrFollowers(l) == IF SyncAck THEN Synced(l) \cap inSync ELSE Synced(l)

(* Server#update_isr, which only the etcd leader can commit *)
IsrNow(l) == {l} \cup IsrFollowers(l)

Unfollow(fs) ==
    /\ following' = [n \in Nodes |-> IF n \in fs THEN NoNode ELSE following[n]]
    /\ link' = [n \in Nodes |-> IF n \in fs THEN "none" ELSE link[n]]
    /\ snap' = [n \in Nodes |-> IF n \in fs THEN NoSnap ELSE snap[n]]
    /\ inSync' = inSync \ fs
    /\ inflight' = [n \in Nodes |-> IF n \in fs THEN {} ELSE inflight[n]]

Init ==
    /\ alive = Nodes
    /\ serving = {}
    /\ etcdLeader = NoNode
    /\ candidates = <<>>
    /\ campaigned = [n \in Nodes |-> FALSE]
    /\ isr = Nodes \* a fresh cluster: every node starts empty and equal
    /\ disk = [n \in Nodes |-> {}]
    /\ following = [n \in Nodes |-> NoNode]
    /\ link = [n \in Nodes |-> "none"]
    /\ snap = [n \in Nodes |-> NoSnap]
    /\ inSync = {}
    /\ inflight = [n \in Nodes |-> {}]
    /\ dirty = [n \in Nodes |-> FALSE]
    /\ published = {}
    /\ written = [n \in Nodes |-> {}]
    /\ dispatched = [n \in Nodes |-> {}]
    /\ confirmed = {}

(* Controller#run: wait_to_be_insync, then campaign once per process. *)
Campaign(n) ==
    /\ n \in alive \ serving
    /\ ~campaigned[n]
    /\ n \in isr
    /\ candidates' = Append(candidates, n)
    /\ campaigned' = [campaigned EXCEPT ![n] = TRUE]
    /\ UNCHANGED <<alive, serving, disk, dirty, etcdLeader, isr, followerVars,
                   msgVars>>

(* The oldest candidacy wins the leader key. Controller#ensure_in_isr!   *)
(* makes a winner outside the ISR exit instead.                          *)
Elect ==
    /\ etcdLeader = NoNode
    /\ candidates /= <<>>
    /\ candidates' = Tail(candidates)
    /\ LET w == Head(candidates) IN
        IF w \in isr
        THEN /\ etcdLeader' = w
             /\ UNCHANGED <<alive, followerVars>>
        ELSE /\ alive' = alive \ {w}
             /\ Unfollow({w})
             /\ UNCHANGED etcdLeader
    /\ UNCHANGED <<serving, disk, dirty, campaigned, isr, msgVars>>

(* Controller#run closes the Client and then starts the Server, which    *)
(* starts with @dirty_isr. Until then the winner still streams from its  *)
(* old leader.                                                           *)
StartServing(w) ==
    /\ w = etcdLeader
    /\ w \in alive \ serving
    /\ serving' = serving \cup {w}
    /\ Unfollow({w})
    /\ dirty' = [dirty EXCEPT ![w] = TRUE,
                              ![following[w]] = IF following[w] /= NoNode /\ link[w] = "synced"
                                                THEN TRUE ELSE dirty[following[w]]]
    /\ written' = [written EXCEPT ![w] = {}]
    /\ dispatched' = [dispatched EXCEPT ![w] = {}]
    /\ UNCHANGED <<alive, disk, etcdVars, published, confirmed>>

(* etcd expires the lease; the node serves on until it notices. *)
LeaseExpire ==
    /\ LeaseExpiry
    /\ etcdLeader /= NoNode
    /\ etcdLeader' = NoNode
    /\ candidates' = Remove(candidates, etcdLeader)
    /\ UNCHANGED <<alive, serving, disk, dirty, campaigned, isr, followerVars,
                   msgVars>>

(* MessageStore#push writes locally first. *)
Write(l, m) ==
    /\ l \in serving
    /\ m \notin published
    /\ published' = published \cup {m}
    /\ written' = [written EXCEPT ![l] = @ \cup {m}]
    /\ disk' = [disk EXCEPT ![l] = @ \cup {m}]
    /\ UNCHANGED <<alive, serving, dirty, etcdVars, followerVars, dispatched,
                   confirmed>>

(* Server#each_follower then streams it to synced followers only (a       *)
(* syncing follower gets it through its full sync) and flushes a dirty    *)
(* ISR. The flush only succeeds for the etcd leader; for a fenced leader  *)
(* it retries forever, so the ISR stays dirty and nothing is confirmed.   *)
Dispatch(l, m) ==
    /\ l \in serving
    /\ m \in written[l]
    /\ written' = [written EXCEPT ![l] = @ \ {m}]
    /\ dispatched' = [dispatched EXCEPT ![l] = @ \cup {m}]
    /\ inflight' = [f \in Nodes |->
                      IF f \in Synced(l) THEN inflight[f] \cup {m} ELSE inflight[f]]
    /\ IF dirty[l] /\ l = etcdLeader
       THEN /\ isr' = IsrNow(l)
            /\ dirty' = [dirty EXCEPT ![l] = FALSE]
       ELSE UNCHANGED <<isr, dirty>>
    /\ UNCHANGED <<alive, serving, disk, etcdLeader, candidates, campaigned,
                   following, link, snap, inSync, published, confirmed>>

(* Persister#drain_pending_acks: syncfs, then Server#wait_for_followers  *)
(* waits for every synced follower to ack all sent bytes and flushes a   *)
(* dirty ISR before the confirm goes out.                                *)
Confirm(l, m) ==
    /\ l \in serving
    /\ m \in dispatched[l]
    /\ ~dirty[l]
    /\ \A f \in Synced(l) : inflight[f] = {}
    /\ dispatched' = [dispatched EXCEPT ![l] = @ \ {m}]
    /\ confirmed' = confirmed \cup {m}
    /\ UNCHANGED <<alive, serving, disk, dirty, etcdVars, followerVars,
                   published, written>>

(* Server#flush_isr, also reached through the lazy paths above. *)
FlushIsr(l) ==
    /\ l \in serving
    /\ l = etcdLeader
    /\ dirty[l]
    /\ isr' = IsrNow(l)
    /\ dirty' = [dirty EXCEPT ![l] = FALSE]
    /\ UNCHANGED <<alive, serving, disk, etcdLeader, candidates, campaigned,
                   followerVars, msgVars>>

(* Controller#follow_leader connects to the leader etcd names. Client    *)
(* #sync_files deletes a file whose hash differs from the leader's before *)
(* requesting it again. With FlushIsrOnSync Server#sync_and_serve first   *)
(* commits the ISR without the follower; for a fenced leader that fails   *)
(* and the follower is dropped.                                           *)
StartSync(f) ==
    /\ etcdLeader \in serving
    /\ f \in alive \ serving
    /\ following[f] = NoNode
    /\ LET l == etcdLeader IN
        /\ following' = [following EXCEPT ![f] = l]
        /\ link' = [link EXCEPT ![f] = "syncing"]
        /\ disk' = IF disk[f] = disk[l] THEN disk ELSE [disk EXCEPT ![f] = {}]
        /\ IF FlushIsrOnSync
           THEN /\ isr' = {l} \cup (IsrFollowers(l) \ {f})
                /\ dirty' = [dirty EXCEPT ![l] = FALSE]
           ELSE UNCHANGED <<isr, dirty>>
    /\ UNCHANGED <<alive, serving, etcdLeader, candidates, campaigned, snap,
                   inSync, inflight, msgVars>>

(* Server#sync_and_serve: the last full_sync is sent, then mark_synced!.   *)
(* Without SyncAck update_isr follows at once, before the follower has   *)
(* written the sync; a failed ISR write drops the follower.              *)
FinishSync(f) ==
    /\ link[f] = "syncing"
    /\ LET l == following[f] IN
        IF SyncAck \/ l = etcdLeader
        THEN /\ snap' = [snap EXCEPT ![f] = disk[l]]
             /\ link' = [link EXCEPT ![f] = "synced"]
             /\ IF SyncAck
                THEN UNCHANGED <<isr, dirty>>
                ELSE /\ isr' = {l} \cup Synced(l) \cup {f}
                     /\ dirty' = [dirty EXCEPT ![l] = FALSE]
             /\ UNCHANGED <<following, inSync, inflight>>
        ELSE /\ Unfollow({f})
             /\ UNCHANGED <<isr, dirty>>
    /\ UNCHANGED <<alive, serving, disk, etcdLeader, candidates, campaigned,
                   msgVars>>

(* The follower writes and syncs the received files, then acks the sync. *)
ApplySync(f) ==
    /\ snap[f] /= NoSnap
    /\ disk' = [disk EXCEPT ![f] = snap[f]]
    /\ snap' = [snap EXCEPT ![f] = NoSnap]
    /\ UNCHANGED <<alive, serving, dirty, etcdVars, following, link, inSync,
                   inflight, msgVars>>

(* Follower#wait_for_sync_ack returns, then update_isr lists the follower; *)
(* for a fenced leader that fails and the follower is dropped.            *)
JoinIsr(f) ==
    /\ SyncAck
    /\ link[f] = "synced"
    /\ f \notin inSync
    /\ snap[f] = NoSnap
    /\ LET l == following[f] IN
        IF l = etcdLeader
        THEN /\ inSync' = inSync \cup {f}
             /\ isr' = {l} \cup (Synced(l) \cap inSync')
             /\ dirty' = [dirty EXCEPT ![l] = FALSE]
             /\ UNCHANGED <<following, link, snap, inflight>>
        ELSE /\ Unfollow({f})
             /\ UNCHANGED <<isr, dirty>>
    /\ UNCHANGED <<alive, serving, disk, etcdLeader, candidates, campaigned,
                   msgVars>>

(* Client#stream_changes: write, syncfs, ack. Streamed after the sync. *)
Apply(f, m) ==
    /\ snap[f] = NoSnap
    /\ m \in inflight[f]
    /\ disk' = [disk EXCEPT ![f] = @ \cup {m}]
    /\ inflight' = [inflight EXCEPT ![f] = @ \ {m}]
    /\ UNCHANGED <<alive, serving, dirty, etcdVars, following, link, snap,
                   inSync, msgVars>>

(* Connection loss, or the follower switching to a new leader. A follower *)
(* behind leaves the ISR at once, a caught-up one stays listed until the  *)
(* dirty ISR is flushed.                                                  *)
Disconnect(f) ==
    /\ following[f] /= NoNode
    /\ LET l == following[f] IN
        /\ Unfollow({f})
        /\ IF link[f] = "synced"
           THEN IF inflight[f] /= {} /\ l = etcdLeader
                THEN /\ isr' = {l} \cup (IsrFollowers(l) \ {f})
                     /\ dirty' = [dirty EXCEPT ![l] = FALSE]
                ELSE /\ dirty' = [dirty EXCEPT ![l] = TRUE]
                     /\ UNCHANGED isr
           ELSE UNCHANGED <<isr, dirty>>
    /\ UNCHANGED <<alive, serving, disk, etcdLeader, candidates, campaigned,
                   msgVars>>

(* A crash, or a leader noticing its lease is gone and exiting. Its       *)
(* candidacy and lease go with it, and so do its pending writes and       *)
(* confirms.                                                              *)
Crash(n) ==
    /\ n \in alive
    /\ alive' = alive \ {n}
    /\ serving' = serving \ {n}
    /\ etcdLeader' = IF etcdLeader = n THEN NoNode ELSE etcdLeader
    /\ candidates' = Remove(candidates, n)
    /\ Unfollow({n} \cup {f \in Nodes : following[f] = n})
    /\ dirty' = [l \in Nodes |->
                   IF l = following[n] /\ link[n] = "synced" THEN TRUE
                   ELSE IF l = n THEN FALSE ELSE dirty[l]]
    /\ written' = [written EXCEPT ![n] = {}]
    /\ dispatched' = [dispatched EXCEPT ![n] = {}]
    /\ UNCHANGED <<disk, campaigned, isr, published, confirmed>>

Restart(n) ==
    /\ n \notin alive
    /\ alive' = alive \cup {n}
    /\ campaigned' = [campaigned EXCEPT ![n] = FALSE]
    /\ UNCHANGED <<serving, disk, dirty, etcdLeader, candidates, isr,
                   followerVars, msgVars>>

Next ==
    \/ Elect
    \/ LeaseExpire
    \/ \E n \in Nodes :
        \/ Campaign(n) \/ StartServing(n) \/ FlushIsr(n)
        \/ StartSync(n) \/ FinishSync(n) \/ ApplySync(n) \/ JoinIsr(n)
        \/ Disconnect(n) \/ Crash(n) \/ Restart(n)
        \/ \E m \in Msgs : Write(n, m) \/ Dispatch(n, m) \/ Confirm(n, m) \/ Apply(n, m)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
TypeOK ==
    /\ alive \subseteq Nodes
    /\ serving \subseteq alive
    /\ etcdLeader \in Nodes \cup {NoNode}
    /\ isr \subseteq Nodes
    /\ inSync \subseteq Nodes
    /\ \A n \in Nodes : disk[n] \subseteq Msgs
    /\ \A n \in Nodes : following[n] /= n
    /\ confirmed \subseteq published

(* What a publisher relies on: the node serving as etcd leader, the one  *)
(* clients reach through the followers' proxies, has every confirmed     *)
(* message, including ones a deposed leader confirmed.                   *)
LeaderHasConfirmed ==
    etcdLeader \in serving => confirmed \subseteq disk[etcdLeader]

(* Sanity: a confirm can happen at all, so the model isn't vacuously safe. *)
NeverConfirms == confirmed = {}

(* Reachability probes: a deposed leader can confirm, but never while     *)
(* another node serves as etcd leader.                                   *)
DeposedCanConfirm ==
    \E l \in serving, m \in Msgs : l /= etcdLeader /\ ENABLED Confirm(l, m)
DeposedConfirmsBesideLeader ==
    \E l \in serving, m \in Msgs :
        l /= etcdLeader /\ etcdLeader \in serving /\ ENABLED Confirm(l, m)

NotDeposedCanConfirm == ~DeposedCanConfirm
NotDeposedConfirmsBesideLeader == ~DeposedConfirmsBesideLeader

(* Sanity: two nodes can serve at once, so LeaseExpiry isn't vacuous. *)
SingleServer == \A a, b \in serving : a = b
=============================================================================
