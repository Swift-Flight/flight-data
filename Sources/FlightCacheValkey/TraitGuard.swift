// Compile-time guard: this target exists only when the "Valkey" trait is on.
// Without it the target's driver dependency is pruned and every file here
// fails with "no such module" — this turns that into an actionable message.
#if !Valkey
#error("""
    FlightCacheValkey requires the "Valkey" trait.

    Consuming flight-data:
        .package(url: "https://github.com/Swift-Flight/flight-data.git", \
                 from: "0.1.0", traits: ["Valkey"])

    Building flight-data itself:
        swift build --enable-all-traits
    """)
#endif
