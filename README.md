# Loci2D — Love2D Client SDK

> 🌐 *Read this in [Português (Brasil)](README.pt-BR.md)*

The **Loci2D Love2D SDK** (`loci_client.lua`) is a high-level abstraction layer designed to allow developers and students to build multiplayer games on the [LÖVE2D](https://love2d.org/) framework with minimal effort, without needing to interact directly with UDP sockets, raw Protocol Buffer buffers, or tick synchronization.

---

## SDK Directory Structure

```text
sdk-love2d/
├── loci_client.lua        # Main client module (API Facade, State Manager, and Netcode)
├── test_sdk.lua           # Unit test suite to validate the SDK locally
├── AI_REFERENCE.md        # Compact API reference formatted for LLMs / AI Agents
├── lib/
│   ├── game_packets.proto # Loci2D Protobuf packet definitions
│   ├── game_packets.pb    # Pre-compiled binary descriptor (ultra-fast loading)
│   └── protoc.lua         # Pure-Lua Protobuf parser (fallback for runtime dynamic parsing)
└── docs/
    ├── index.html         # Interactive visual guide for Love2D game development
    └── server_scripts.html# Guide for authoring server-side game rules
```

---

## Schema Loading Mechanism

`loci_client.lua` is designed for maximum fault tolerance across different environments:
1. **Pure-Lua Parser (`protoc.lua`):** Parses and registers `.proto` text schemas at runtime without requiring external compiler binaries.
2. **Pre-compiled Descriptor (`game_packets.pb`):** If runtime parsing is bypassed or unnecessary, the SDK loads the binary descriptor directly via `pb.loadfile()`.

---

## Prerequisites

If you have already verified your environment via the root script (`./tools/setup_environment.sh`), Love2D is ready to go. Otherwise:

1. **LÖVE 11.x+**: Installed on your system ([love2d.org](https://love2d.org/)).
2. **lua-protobuf (`pb`)**: Fast C/Lua binary module for Protobuf encoding and decoding.
   * **Linux:** `sudo luarocks install lua-protobuf` (or place `pb.so` inside `lib/`).
   * **Windows:** Place `pb.dll` in your project root or inside `lib/`.
   * **macOS:** `luarocks install lua-protobuf`.

---

## Testing the SDK Locally

Before launching your game in Love2D, you can verify that all abstractions (such as `Entity` metatables, auto-typed property casting, spatial radius queries, and event dispatching) are functional on your system by running:

```bash
lua test_sdk.lua
```

If the environment is configured correctly, the test suite will output:
```text
All loci_client.lua SDK unit tests passed successfully!
```

---

## Quickstart Integration Example

```lua
-- main.lua
package.path = package.path .. ";./loci2d/?.lua;./?.lua"
local loci = require("loci_client")

function love.load()
    -- Connect to the authoritative server
    loci.connect("127.0.0.1", 8080, "Player1")

    loci.on_action_cast = function(entity, ability_id, dir_x, dir_y)
        print("Ability cast by entity:", entity.id)
    end
end

function love.update(dt)
    -- Process incoming network packets and interpolate entities
    loci.update(dt)

    -- Send movement input
    local dx, dy = 0, 0
    if love.keyboard.isDown("w") then dy = -1 end
    if love.keyboard.isDown("s") then dy = 1 end
    if love.keyboard.isDown("a") then dx = -1 end
    if love.keyboard.isDown("d") then dx = 1 end
    loci.send_move(dx, dy)
end

function love.draw()
    for _, entity in ipairs(loci.get_entities()) do
        if entity:is_local_player() then
            love.graphics.setColor(0.3, 0.6, 1.0)
        else
            love.graphics.setColor(0.3, 0.8, 0.4)
        end
        love.graphics.circle("fill", entity.x, entity.y, 16)
    end
    -- Draw network telemetry overlay if active (F3)
    loci.draw()
end

function love.keypressed(key)
    loci.keypressed(key) -- F3: Toggle HUD | F4: Export CSV
end

function love.quit()
    loci.quit()
    loci.disconnect("Game closed")
end
```

---

## Network Telemetry & Localhost Validation (`tc`/`netem`)

The SDK provides high-precision, **Zero-GC** network telemetry to measure RTT, RFC 3550 Jitter, Packet Loss %, and Snapshot Arrival Frequency (Hz).

* **F3**: Toggle on-screen debug HUD (`[REDE] Ping: 42ms (min: 35 | max: 85) | Jitter: 8.2ms | Loss: 1.2% | Tick: 30.1 Hz`).
* **F4**: Export raw CSV log to `logs/network_stats_<timestamp>.csv`.
* **Export on Exit**: Automatically flushed via `loci.quit()`.

### Localhost Simulation (Linux `tc`/`netem`)

To validate telemetry metrics against synthetic perturbations on `127.0.0.1`:

* **Stable Wi-Fi (40ms latency, ±5ms jitter, 0.5% loss):**
  ```bash
  sudo tc qdisc add dev lo root netem delay 40ms 5ms loss 0.5%
  ```

* **Congested Wi-Fi (80ms latency, ±25ms jitter, 5% loss):**
  ```bash
  sudo tc qdisc add dev lo root netem delay 80ms 25ms loss 5%
  ```

* **Bursts & Packet Reordering (60ms latency, 25% reordered):**
  ```bash
  sudo tc qdisc add dev lo root netem delay 60ms 10ms reorder 25% 50%
  ```

* **Restore Normal Localhost (remove rules):**
  ```bash
  sudo tc qdisc del dev lo root
  ```

For the complete interactive guide, open `docs/index.html` in your browser.
