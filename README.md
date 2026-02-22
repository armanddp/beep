# beep

A macOS command-line tool that monitors fan speeds and temperatures by reading directly from the System Management Controller (SMC) via IOKit. Built in Swift for the lowest-level access to Apple Silicon hardware diagnostics.

Originally created to diagnose a stuck right fan on a 2023 14" M2 Pro MacBook Pro that was causing intermittent beeping under load.

## What it does

```
beep Fan & Thermal Monitor
MacBook Pro 14" M2 Pro  │  10:34:53
────────────────────────────────────────────────────────

  Left Fan                    Right Fan
  ● 2329 RPM                  ✗ 0 RPM ← STALLED

  Temperatures
  CPU E-Core 2   47.6°C       Airflow Left   39.8°C
  Battery        35.2°C

  ⚠  CRITICAL: Right Fan is NOT SPINNING! (other fan at 2329 RPM) — fan may be stuck or dead

Ctrl+C to exit  │  Refresh: 1s
```

- Reads fan RPM for all fans (left/right on dual-fan MacBook Pros)
- Reads temperatures from available SMC sensors
- Detects **stalled** fans (not spinning while the system needs cooling), **underperforming** fans (spinning well below target), and **asymmetric** behaviour (one fan significantly slower than the other)
- Live-updates in the terminal with colour-coded status indicators

## Requirements

- macOS 13 (Ventura) or later
- Swift 5.9+ (included with Xcode 15+)
- Apple Silicon or Intel Mac with SMC access

## Build and run

```bash
swift build
.build/debug/beep
```

Or build an optimised release binary:

```bash
swift build -c release
cp .build/release/beep /usr/local/bin/beep
```

If you see "No fans detected", the SMC may require elevated privileges:

```bash
sudo .build/debug/beep
```

## Options

| Flag | Description |
|---|---|
| `--once` | Run a single check and exit instead of live monitoring |
| `--interval N` | Set the refresh interval in seconds (default: `1.0`, minimum: `0.5`) |
| `--silence` | Temporarily mute macOS alert sounds while monitoring (see below) |
| `--disable-fan N` | Disable fan N in the SMC (requires sudo) |
| `--dump` | Enumerate and print all readable SMC keys with their values, then exit |
| `--help`, `-h` | Show usage help |

### `--once`

Takes a single snapshot of fan speeds and temperatures and prints it to stdout. Useful for scripting or quick checks:

```bash
.build/debug/beep --once
```

### `--interval`

Controls how often the display refreshes during live monitoring. Lower values give more responsive updates but use slightly more CPU:

```bash
.build/debug/beep --interval 0.5   # refresh every 500ms
.build/debug/beep --interval 5     # refresh every 5 seconds
```

### `--silence`

Temporarily mutes macOS **alert sounds** to suppress thermal warning beeps while you monitor the situation. The original alert volume is restored automatically when the tool exits (via Ctrl+C or `--once` completion):

```bash
.build/debug/beep --silence
```

The footer shows an **Alerts muted** indicator while silencing is active. This works by setting the macOS alert volume to 0 via `osascript` — it does not affect media playback volume.

> **Note:** If the beeping originates from SMC firmware directly (bypassing CoreAudio), this flag will have no effect. In that case, the beeps are hardware-level.

### `--disable-fan`

**Permanently disables a stuck or dead fan** at the SMC level, preventing the system from trying to spin it up (and thus stopping the beeping):

```bash
sudo .build/debug/beep --disable-fan 1     # Disable right fan
sudo .build/debug/beep --disable-fan 0     # Disable left fan
```

This flag:
- Requires `sudo` (writes directly to the SMC)
- Disables the specified fan by writing to the `FnEn` SMC key
- Stops the SMC from repeatedly trying to spin up that fan
- Eliminates beeps from the non-responsive fan
- **Cannot be undone without a system reboot** (or writing a new value back)

**Use this only if:**
- You've confirmed with `beep` that a fan is not spinning (0 RPM)
- The system is beeping frequently because it keeps trying to start that fan
- You're waiting for a hardware repair and want to silence the repeated alerts
- You understand this disables thermal management for that fan

**Safety note:** Disabling a fan removes an important cooling mechanism. This is safe in the short term for a dead fan on an idle system, but avoid running heavy workloads with a disabled cooling fan.

### `--dump`

Reads every SMC key the system exposes and prints the ones that return reasonable numeric values. Useful for discovering what sensor data is available on your specific Mac model:

```bash
.build/debug/beep --dump
```

Example output:

```
SMC reports 542 keys. Reading...

  #KEY    type=ui32  size=4  hex=[00 00 02 1E]  value=542.00
  F0Ac    type=flt   size=4  hex=[45 0B 80 00]  value=2232.00
  F1Ac    type=flt   size=4  hex=[00 00 00 00]  value=0.00
  Tp01    type=flt   size=4  hex=[42 4C CC CD]  value=51.20
  ...
```

## How it works

The tool communicates with the AppleSMC kernel driver through IOKit's `IOConnectCallStructMethod`. The protocol uses a fixed 80-byte struct (`SMCKeyData_t`) to request key info and read values from the SMC.

Key SMC keys used:

| Key | Description |
|---|---|
| `FNum` | Number of fans |
| `F0Ac`, `F1Ac` | Actual fan speed (RPM) |
| `F0Tg`, `F1Tg` | Target fan speed (RPM) |
| `F0Mn`, `F0Mx` | Fan speed min/max range |
| `Tp09`, `Tp01`, etc. | CPU core temperatures |
| `TaLP`, `TaRP` | Airflow temperatures (left/right) |
| `TB0T` | Battery temperature |

On Apple Silicon, fan speed values use `flt` (IEEE 754 float) encoding. The tool also handles Intel's `fpe2` (fixed-point 14.2) and `sp78` (signed 8.8) formats for broader compatibility.

Temperature key availability varies by Mac model. The tool tries a curated list of known keys and displays whichever ones return valid readings on your hardware.

## Fan health detection

The tool uses context-aware logic to classify each fan's status:

- **Normal** (`●` green) — fan is spinning as expected
- **Idle** (`○` dim) — fan is off and no cooling demand detected
- **Stalled** (`✗` red) — fan is not spinning despite cooling demand. Detected when:
  - The SMC reports a target speed > 100 RPM but actual speed is near 0, or
  - The other fan is spinning significantly (> 500 RPM) while this one is not
- **Underperforming** (`▼` yellow) — fan is spinning at less than 50% of its target speed

## License

MIT
