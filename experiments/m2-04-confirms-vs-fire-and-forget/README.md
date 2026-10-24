# M2-04 — Fire-and-forget vs publisher confirms

**Date:** 2026-10-24 · **Module:** 2 RabbitMQ · **Status:** done

## Hypothesis

A publisher connected to server-0, which is also the quorum-queue leader, and server-0 is killed under load:
1. **Without confirms**, messages the publisher has "sent" are lost, and it can't tell which ones. The loss grows with the rate.
2. **With confirms**, no confirmed message is lost. The publisher knows exactly which messages are uncertain.

## Setup

RabbitMQ 4.3.7, 3 nodes, quorum queue `m2-04`, leader on server-0. `probe.js` has a new **`fire`** mode: a plain channel, with `sent <seq>` logged once `sendToQueue` returns. That's all a client without confirms ever knows. `publish` mode is M2-01's confirm channel (window 100). The publisher doesn't reconnect. Drain through server-1 afterwards.

**Promised** = what the publisher can claim it delivered: confirmed (confirm mode), or sent (fire mode). **Lost** = promised and not in the queue.

## Fault / action

`./run.sh experiment <confirm|fire> <kill|delete> [n]`, with `RATE=` (default 500/s): 20 s of publishing, then server-0 SIGKILLed (Chaos Mesh) or deleted (graceful).

## Observed

| Mode | Fault | Rate (target → actual) | Sent | Promised | In queue | **Lost** | Uncertain, and what happened to them |
| --- | --- | --- | --- | --- | --- | --- | --- |
| fire | kill | 500 → 500/s | 10,667 | 10,667 | 10,666 | **1** (the last one sent) | client doesn't know any are uncertain |
| fire | delete | 500 → 500/s | 11,632 | 11,632 | 11,631 | **1** (the last one sent) | client doesn't know |
| fire | kill | 5,000 → 5,000/s | 106,805 | 106,805 | 106,790 | **15** (the last 15, sent in the final 2 ms) | client doesn't know |
| confirm | kill | 500 → 500/s | 10,664 | 10,659 | 10,663 | **0** | **5 nacked** on close: 4 were in the queue, 1 not |
| confirm | kill | 5,000 → **3,700/s** | 86,723 | 86,623 | 86,701 | **0** | **100 nacked** (the whole window): 78 in the queue, 22 not |

- In fire mode, every lost message was in the **tail**: sent in the last few ms before the client saw the channel close. Everything earlier had already been committed by Raft on the two survivors.
- In confirm mode, amqplib **nacks every outstanding message when the channel closes**. So the client ends with an exact list of messages it has to treat as unknown. Some of them reached the queue anyway (4 of 5, 78 of 100): a nack on close means "unknown", not "failed".
- Confirms cost throughput: with a window of 100, confirm mode reached 3,700/s against fire's 5,000/s. The window divided by the confirm latency (~27 ms here) is the ceiling.

## Result

1. **Fire-and-forget loses messages silently: confirmed, though fewer than expected.** It lost 1 message at 500/s and 15 at 5,000/s, always the most recent ones, and the client believed they were all delivered. The count is small here because Raft on three nearby nodes commits in milliseconds, so little is in flight. It grows with the rate and with commit latency: slower disks, WAN links, a broker under memory pressure.
2. **Confirms: confirmed.** 0 lost in both runs, and an exact list of the uncertain ones.

The real difference isn't the loss count, it's **knowledge**. With confirms, the publisher can resend exactly the uncertain messages (at-least-once). Without them, it can't know there's anything to resend. Its only choices are to resend everything since some point (duplicates) or to accept unknown gaps.

## Fix

None for the broker. For the saga services:
- **Always use confirms** for commands. Resend what was nacked or timed out (M2-02's confirm timeout), with a stable message id. 78 of 100 nacked messages were already in the queue, so resending them **will** create duplicates. Consumers have to deduplicate (M2-05).
- The outbox relay marks a row "sent" only on a confirm.
- Size the window for the throughput you need: rate ≈ window / confirm latency.

## Lessons

- **"Sent" is a client-side illusion.** `sendToQueue` returning means the bytes reached a local buffer, not the broker's disk, and not a majority.
- **Uncertain is a third state, between delivered and failed.** Confirms don't remove it, they bound and name it (≤ window). Everything after this card has to handle "maybe".
- **Small losses still matter.** One lost command in a saga is one order stuck forever, and with fire-and-forget nobody would ever find out which one.
