# ProFireDriver

A DriverKit audio driver that makes the **M-Audio ProFire 2626** (TCAT DICE II, FireWire 400)
a working Core Audio sound card again on Apple Silicon. macOS no longer has a FireWire stack,
so this driver includes its own: OHCI controller, async transactions, DICE control,
isochronous AM824 streaming, and an AudioDriverKit device.

## Status (2026-11-10)

- **Core Audio sees it:** "ProFire 2626", 26 in / 26 out, channel names come from the device.
- **Sample rates:** 44.1, 48, 88.2 and 96 kHz work. 176.4 and 192 kHz aren't offered yet; they need DICE dual-wire handling.
- **Measured with loopback cables:**
  - Analog: output 8 → input 6.
  - ADAT: optical out A → in B, bit-exact, 0 glitches in 60 s at 48 kHz.
  - 1 kHz test tone at exactly 1000.0 Hz.
- **Stream alignment:** ADAT (stream 1) is sample-aligned to the analog/S/PDIF stream (stream 0) by SYT presentation time. The DICE skews its two streams by 1024 ticks, and the driver compensates.
- **Recovery:** a FireWire bus reset mid-stream is recovered in about 2 s. If the ProFire was power-cycled, recovery takes about 4 s, because its host routing has to be reloaded.

## Hardware

| Piece | Details |
|---|---|
| Mac | MacBook Pro M1, macOS 27.0.1 |
| FireWire controller | LSI FW643 (`11c1:5901` rev 08) in a **Belkin Thunderbolt Express Dock** |
| Device | M-Audio ProFire 2626 over FW800 → FW400 |

The dext matches only the FW643 (`IOPCIMatch 0x590111c1`, `IOPCITunnelCompatible`).

## How it works

| File | Role |
|---|---|
| `ProFireOHCI/FWController.*` | OHCI bring-up, bus resets/self-IDs, config ROM, async read/write/lock (32/64-bit compare-swap), physical-DMA notifications |
| `ProFireOHCI/Dice.*`, `DiceRegs.h` | DICE ownership, clock select, stream formats, IRM channel/bandwidth allocation, EAP router + stream config load |
| `ProFireOHCI/Amdtp.*` | IR/IT DMA rings (packet-per-buffer, 256 packets each), AM824 encode/decode, timestamps |
| `ProFireOHCI/ProFireOHCI.*` | `IOUserAudioDriver`: discovery, Core Audio device, start/stop, rate changes, developer commands |
| `ProFireOHCI/ProFireAudioDevice.*` | `IOUserAudioDevice` subclass forwarding StartIO/StopIO/rate changes |
| `ProFireLoader/` | SwiftUI app that installs the dext (`--activate` / `--deactivate`) |
| `tools/pfctl.c` | developer commands to the running driver |
| `tools/pftest.swift` | Core Audio loopback test: tone on one output, peaks for all inputs, glitch analysis of one input |
| `tools/deploy.sh` | install + activate + hands-free switch to the new build |

### Streaming design

- **Device → Mac:** one IR context per DICE TX stream, polled every 1 ms. Samples are converted from 24-bit to float32 into Core Audio's input ring (4096 frames, which is also the zero-timestamp period). Zero timestamps come from IR packet cycle stamps mapped to host time through the OHCI cycle timer.
- **Mac → device:** one IT context per DICE RX stream. Each received cycle is replayed 48 cycles (6 ms) later with the same data-block count and its SYT shifted by the same delay. That keeps the outgoing streams locked to the ProFire's media clock, the approach Linux uses for DICE.
- **Secondary RX streams** keep their own sequential frame counter. It's anchored to stream 0 by SYT presentation time (only from 100 ms after start) and checked against every full packet.

## Things the ProFire needs (learned the hard way)

1. **Re-select the clock right after taking ownership,** even if the rate doesn't change. Without that the DICE transmits all-zero audio slots. Linux snd-dice does the same, with the comment "selecting clock parameters have an effect for the unit to refine it".
2. **Load the host router and stream config** (EAP `LD_ROUTER`, `LD_STRM_CFG` for the low/mid/high modes) from the device's stored current config. At power-on it runs its standalone routing, which doesn't feed the FireWire streams.
3. **Front-panel master volume knob:** application space `[0] = 0x0f` puts all four output pairs under the knob, so output level follows the knob.

## DriverKit / macOS lessons

- **`IOPCITunnelCompatible`** is required for PCI devices behind Thunderbolt.
- **`IOUserAudioDriverUserClientProperties`** in the personality is what lets Core Audio discover the device. `UserClientProperties` alone isn't enough.
- **No page-crossing descriptor blocks:** OHCI can't fetch a descriptor block that crosses a 4 KiB page (`evt_descriptor_read`). IT blocks are padded to 64 bytes.
- **IT skip address** points at its own block, as in Linux.
- **Dext logs only show live:** use `/usr/bin/log stream` (zsh has its own `log`). `log show` doesn't have them.
- **SetProperties doesn't reach an `IOUserAudioDriver`,** so developer commands go through `IOServiceOpen` types handled in `NewUserClient`.
- **Upgrades:** macOS won't stop an in-use PCI dext. `pfctl restart` makes it `abort()`, DriverKit relaunches it with the newest personality (each build raises `IOProbeScore` to 10000 + build), and the kernel allows 5 crashes per boot. sysextd sometimes keeps a "terminating" entry until reboot ("activateDecision found two entries"), and then a reboot is needed before the next activation.

## Build and install

Requirements: full Xcode with the DriverKit SDK, **SIP disabled** and `systemextensionsctl developer on`. The dext is ad-hoc signed, and Apple would have to grant the DriverKit PCI and audio entitlements for it to run with SIP on.

```bash
./build.sh            # builds, bumps the version and probe score, ad-hoc signs, builds pfctl
tools/deploy.sh       # installs to /Applications, activates, switches to the new build, prints the log
```

The first install needs approval in **System Settings › General › Login Items & Extensions › Driver Extensions**. After that the driver loads at boot.

## Developer commands

```bash
build/pfctl dump                 # DICE clock/stream summary
build/pfctl tone                 # start streams with a 1 kHz tone on output 8 + input level logging
build/pfctl tone 11              # tone on another output (1-based)
build/pfctl stop
build/pfctl router               # dump EAP sections and routers
build/pfctl peekx 0x13a          # read 16 quadlets of EAP space (quadlet index); peekb for DICE base space
build/pfctl raw                  # log raw contents of the next received packets
build/pfctl busreset             # force a FireWire bus reset
build/pfctl zts                  # toggle zero-timestamp logging
build/pfctl restart              # exit; DriverKit relaunches the newest installed version
build/pftest 8 10 -12 6          # Core Audio: tone on out 8 for 10 s at -12 dBFS, analyse in 6
build/pftest 11 60 -12 19 48000  # ADAT A->B loop at 48 kHz for 60 s
```

Live log:

```bash
/usr/bin/log stream --level debug --predicate 'eventMessage CONTAINS "ProFireOHCI"'
```

## Known gaps

- **176.4/192 kHz:** not offered. Needs dual-wire handling.
- **88.2/96 kHz:** the ADAT ports run in S/MUX, so the device keeps 26 channels and some ADAT channels are silent or mapped differently at these rates.
- **CLOCK_ACCEPTED notifications** don't arrive at the physical-DMA notification address. Clock changes are confirmed by polling lock status instead.
- **MIDI** ports are carried as empty slots and not yet exposed.
- **Startup:** a handful of glitch samples can occur in the first moments after a stream starts.
- **No mixer/control panel.** The router follows the device's stored host configuration.

## Reference material

`reference/m-audio-2.4.4/` (gitignored, M-Audio's copyright) has the original 2.4.4 kext,
the mixer app's device descriptions, and the 2626 firmware image. Useful external references:
Linux `sound/firewire/dice/*` and FFADO `src/dice/` (including `src/dice/maudio/profire_2626.*`).

## Uninstall

```bash
open /Applications/ProFireLoader.app --args --deactivate
```
