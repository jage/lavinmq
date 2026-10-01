"""Where LavinMQ knowingly differs from the reference model, and how the
campaign deals with it.

A quirk either mirrors LavinMQ in the model (`mirror`), so the campaign goes
on looking for other differences, or keeps the op generator away from it
(`avoid`), because it would end the run or hang the broker. Each one is a bug
or an intended difference, with its issue or finding id.

The campaign runs with every quirk on. `--strict ID` turns one off: the
model then follows the specification there, or the generator stops avoiding
it, so a divergence shows the quirk is still there and none shows it's fixed.
`hazard` quirks hang or wedge the broker, so `--strict all` leaves them on;
name them to turn them off."""
from dataclasses import dataclass

# finding ids (F...) are from the model-based campaign of 2026-09; see
# verification/nightly/README.md


@dataclass(frozen=True)
class Quirk:
    id: str
    mode: str          # mirror or avoid
    kind: str          # bug or difference
    ref: str
    description: str
    hazard: bool = False


QUIRKS = {q.id: q for q in [
    Quirk("unbind-missing-ok", "mirror", "difference", "F1, amqp/client.cr unbind_queue",
          "queue.unbind and exchange.unbind of a missing queue or exchange reply unbind-ok, not 404"),
    Quirk("x-match-with-x", "mirror", "difference", "F2, docs/exchanges.md",
          "x-match all-with-x and any-with-x are refused with 406"),
    Quirk("max-length-bytes-whole-message", "mirror", "difference", "F3",
          "x-max-length-bytes counts the whole stored message, not only the body"),
    Quirk("delay-zero-delayed", "mirror", "difference", "F4",
          "any x-delay header, even 0, goes through the delayed queue, so a mandatory publish is never returned"),
    Quirk("ttl-zero-behind-head", "mirror", "bug", "F5",
          "a TTL 0 message behind another is delivered later if a consumer attaches, not expired"),
    Quirk("reject-publish-bytes-at-limit", "mirror", "bug", "F6",
          "reject-publish refuses a message that would exactly fill x-max-length-bytes"),
    Quirk("reject-publish-dlx-is-drop-head", "mirror", "bug", "F7",
          "x-overflow reject-publish-dlx acts as drop-head: the publish is acked and the oldest message dead-lettered"),
    Quirk("overflow-policy-wins", "mirror", "difference", "F8",
          "an overflow policy overrides the x-overflow argument; other arguments override policies"),
    Quirk("no-expiry-with-consumers", "mirror", "bug", "F9",
          "expired messages are neither removed nor dead-lettered while the queue has a consumer"),
    Quirk("qos-updates-consumers", "mirror", "difference", "F13",
          "basic.qos global=false also changes the prefetch of the channel's existing consumers"),
    Quirk("reject-publish-returns", "mirror", "bug", "F14",
          "a mandatory publish refused by a full reject-publish queue gets basic.return 312 NO_ROUTE"),
    Quirk("if-unused-counts-destination", "mirror", "difference", "F15",
          "exchange.delete if-unused refuses an exchange that is only the destination of an exchange binding"),
    Quirk("zero-limit-delivers", "mirror", "difference", "F16, queue.cr drop_overflow",
          "a max-length 0 queue delivers to a consumer with capacity instead of dropping"),
    Quirk("cycle-detection-newest-rejection", "mirror", "difference", "F18, docs/dead-lettering.md",
          "dead-letter cycle detection stops only at a rejection newer than the matching death"),
    Quirk("expiry-not-rearmed-on-drop", "mirror", "bug", "F21",
          "dropping the head for max-length doesn't re-arm the expire timer for the new head"),
    Quirk("bcc-stored", "mirror", "bug", "F22",
          "BCC is stored with the message, counts against x-max-length-bytes, and is stripped only on delivery"),
    Quirk("zero-bytes-limit-skipped", "mirror", "bug", "F23, queue.cr drop_overflow",
          "the zero-limit case is skipped for x-max-length-bytes 0 when x-max-length is set too"),
    Quirk("policy-tie-last-wins", "mirror", "difference", "F24, vhost.cr apply_policies",
          "of two policies with the same priority, the one defined last applies"),
    Quirk("auto-delete-exchange-survives-restart", "mirror", "bug", "F25",
          "an auto-delete exchange whose only binding was to a transient queue survives a restart"),
    Quirk("delayed-ttl-from-publish", "mirror", "bug", "F27",
          "a delayed message's TTL counts from its publish, not from when it reaches the queue"),
    Quirk("alternate-exchange-per-pass", "mirror", "difference", "F31",
          "the alternate exchange is used when no queue has been found yet in the routing pass, "
          "even if an exchange binding matched"),
    Quirk("reject-publish-drops-on-apply", "mirror", "bug", "K2, fixed on verification-overnight 686caa05",
          "applying a policy, or a requeue, drops messages over the limit even with reject-publish"),
    Quirk("duplicate-consumer-tag", "avoid", "bug", "#2202",
          "a second basic.consume with a tag in use on the channel is accepted"),
    Quirk("exclusive-consume-beside-others", "avoid", "bug", "#2202",
          "an exclusive basic.consume is granted while the queue has other consumers"),
    Quirk("recover-no-requeue-541", "avoid", "bug", "F12",
          "basic.recover requeue=false with an unacked delivery to a live consumer closes the connection with 541"),
    Quirk("recover-in-tx-loses-acks", "avoid", "bug", "F26",
          "basic.recover requeue=true inside a transaction loses the messages acked in it"),
    Quirk("tx-delayed-corrupts", "avoid", "bug", "F20",
          "a transaction that publishes to a delayed exchange corrupts the messages published after it"),
    Quirk("tx-ack-all-541", "avoid", "bug", "track 4",
          "basic.ack tag 0 multiple inside a transaction with nothing unacked closes the connection with 541"),
    Quirk("delivery-count-lost-on-restart", "avoid", "bug", "#1911",
          "x-delivery-count, and with it x-delivery-limit, starts over after a restart"),
    Quirk("qos-below-unacked", "avoid", "difference", "F13",
          "lowering a consumer's prefetch below its unacked count still lets one more message through"),
    Quirk("dead-letter-ping-pong", "avoid", "bug", "F19", hazard=True,
          description="two queues dead-lettering to each other for different reasons loop forever and hang the broker"),
    Quirk("qos-zero-spins", "avoid", "bug", "F28, fixed on verification-overnight 245804ca", hazard=True,
          description="basic.qos 0 on a channel with unacked deliveries spins a core and can strand a message"),
]}

_enabled = set(QUIRKS)


def on(quirk_id):
    """True while LavinMQ's behaviour is mirrored or avoided for this quirk."""
    if quirk_id not in QUIRKS:
        raise KeyError(quirk_id)
    return quirk_id in _enabled


def strict(ids):
    """Turn quirks off: a list of ids, or ["all"] for every one that isn't a hazard."""
    global _enabled
    ids = list(ids)
    if "all" in ids:
        ids = [q.id for q in QUIRKS.values() if not q.hazard] + [i for i in ids if i != "all"]
    for i in ids:
        if i not in QUIRKS:
            raise KeyError(f"no quirk {i!r}")
    _enabled = set(QUIRKS) - set(ids)
    return sorted(set(QUIRKS) - _enabled)
