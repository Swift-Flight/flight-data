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
Valkey restart must not finish it. The subscribe loop retries with backoff and
the stream stays open; the relay above never learns it happened, beyond a gap
in delivery.

## Shutting down

``FlightPubSubValkeyModule``'s service stops the relay *before* the client
pool, rather than cancelling both together. Releasing a subscription
connection while it is still initializing trips a fatal assertion inside
valkey-swift and takes the process down during what should be a graceful
stop. Ordered shutdown avoids it.

## Topics

### Wiring

- ``FlightPubSubValkeyModule``
- ``ValkeyPubSubSettings``

### The adapter

- ``ValkeyPubSubAdapter``

### Failure

- ``ValkeyPubSubConfigurationError``
