# beep

Swift CLI tool for macOS fan and thermal monitoring via SMC (System Management Controller).

## Build

```
swift build
```

## Run

```
.build/debug/beep
```

## Project Structure

- `Sources/beep/SMC.swift` - Low-level SMC communication via IOKit (struct definitions, key reading, value parsing)
- `Sources/beep/FanMonitor.swift` - Fan and temperature data models, health detection, warning logic
- `Sources/beep/Display.swift` - ANSI terminal rendering (fan status, temps, warnings)
- `Sources/beep/AlertSilencer.swift` - macOS alert sound muting via osascript
- `Sources/beep/main.swift` - Entry point, argument parsing, main loop

## Key Technical Details

- SMCKeyData_t struct must be exactly 80 bytes for IOConnectCallStructMethod
- Apple Silicon uses `flt` (IEEE 754 float) for fan speeds; Intel uses `fpe2` (fixed-point 14.2)
- SMC bytes are big-endian with fallback to native order for `flt` type
- Fan 0 = Left, Fan 1 = Right on 14" MacBook Pro
- Temperature keys vary by model; code tries multiple candidates and keeps what returns valid data
