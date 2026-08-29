# ``FlightPubSubValkey``

Carries Flight's PubSub between nodes over Valkey, which is what turns three
single-node features into clustered ones.

## Overview

`FlightPubSub` delivers within a process on its own. This is the hop
*between* processes, and registering it is the entire change:

```swift
try await Flight.bootstrap(configuration: try Configuration.load(), modules: [
    FlightPubSubValkeyModule.self,   // pulls in FlightPubSubModule
    AppModule.self,
])
```

```yaml
pubsub:
  valkey:
    url: valkey://localhost:6379
```

The URL takes the same shapes as every other Valkey connection in this
package — `valkey://` and `redis://` are synonyms, `valkeys://` and `rediss://`
are the same with TLS, `valkey://:secret@host/2` is password-only auth against
database 2 — and the rest of `pubsub.valkey.*` is optional:

| Key | Default | What it bounds |
|---|---|---|
| `pubsub.valkey.url` | — | required |
| `pubsub.valkey.channel` | `flight-pubsub` | the one channel every node shares |
| `pubsub.valkey.command_timeout_ms` | 250 | a command on a leased connection |
| `pubsub.valkey.unreachable_after_ms` | the command timeout | how long the pool tries to connect before failing fast |
| `pubsub.valkey.retry_delay_ms` | 1000 | the first delay before re-subscribing |

Nothing that publishes or subscribes changes. `FlightPubSubModule` composes
by *presence*: its `any PubSub` factory runs at `freeze()`, finds a registered
`DistributedPubSubAdapter`, and hands the application a `ClusteredPubSub`
instead of the local core.

Three things become clustered at once, because all three are built on PubSub:

- **Channels** — a broadcast reaches sockets connected to other servers
- **Presence** — the membership mode has a transport to gossip over
- **`ClusteredPubSub`** — reachable at all, rather than a type with no adapter

## What it promises, and what it does not

Valkey's pub/sub is **at-most-once and fire-and-forget**. A node that is
disconnected at the moment of a publish does not get that message later:
there is no replay, no acknowledgement, and no ordering guarantee across
channels.

That is the right shape for what this carries — presence diffs, chat fan-out,
cache invalidation — where the next update supersedes the last and a dropped
one costs a moment of staleness. It is the wrong shape for work that must not
be lost. A job queue wants a queue.

`ClusteredPubSub` takes the same posture deliberately: a failed broadcast is
logged and dropped rather than thrown, so a lost hop never becomes a crashed
publisher.

## One channel, every topic

Every node publishes to and subscribes to a single Valkey channel, and a
Flight `Message` names its own topic inside the frame. A channel per topic
would mean re-subscribing every time a socket joined a room, which is the
common case in exactly the applications this is for.

Override `pubsub.valkey.channel` to run two independent Flight clusters
against one Valkey.

## Echo, and why it is harmless

Valkey delivers a publish back to the publishing connection's own
subscribers. Without care, a local subscriber would see every message twice —
once from local fan-out and once off the wire.

`ClusteredPubSub` stamps each broadcast with an origin node ID and drops
self-originated arrivals, so this is already handled. The adapter's job is
simply to carry metadata faithfully, and a test asserts a local subscriber
sees a message exactly once.

## Reconnection

A finished `incoming()` stream means "this adapter is done for good", so a
Valkey restart must not finish it. The subscribe loop retries and the stream
stays open; the relay above never learns it happened, beyond a gap in delivery.

The delay starts at `pubsub.valkey.retry_delay_ms`, doubles to a 30-second cap,
and is jittered by ±50%. The jitter is the point: every node in a cluster loses
the server at the same instant, so a fixed delay has all of them reconnect at
the same instant too — a thundering herd aimed at a server that has just come
back up.

## What crosses the wire

A small JSON header — the topic and the metadata — then the payload bytes
verbatim:

```
"FPS1"                4 bytes, magic and version
UInt32 big-endian     header length
header                {"topic": …, "metadata": {…}}
payload               the caller's bytes, untouched
```

This used to be `Codable` over the whole message, and `JSONEncoder` renders
`Data` as base64 — so every payload byte was inflated by a third and re-encoded
on each hop, on exactly the chat-fan-out and presence-diff traffic this is for.

The magic is a version: a node running an incompatible build sees a frame it
cannot read and drops it loudly rather than decoding it into nonsense. One
undecodable frame never takes down the relay for every other node.

## Shutting down

``FlightPubSubValkeyModule``'s service stops the relay *before* the client
pool, rather than cancelling both together. Releasing a subscription
connection while it is still initializing trips a fatal assertion inside
valkey-swift and takes the process down during what should be a graceful stop.

"Before" is enforced by waiting for the subscribe loop to actually finish. It
used to be a 50 ms sleep, which under cancellation throws immediately and was
swallowed — so on the one path most likely to hit the race, the pool was
cancelled with the subscription still unwinding.

## Topics

### Wiring

- ``FlightPubSubValkeyModule``
- ``ValkeyPubSubSettings``

### The adapter

- ``ValkeyPubSubAdapter``

### Configuration keys

- ``ValkeyPubSubConfigKey``

### Failure

- ``ValkeyPubSubConfigurationError``
