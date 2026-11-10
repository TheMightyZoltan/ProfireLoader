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

## ProFire Control (the control panel)

`/Applications/ProFireLoader.app`, shown as **ProFire Control**, replaces M-Audio's ProFire control panel:

| Tab | What it does |
|---|---|
| **Mixer** | All 18 DICE mixer inputs, in 9 linkable pairs. Each has a source (analog, ADAT A/B, S/PDIF, software return 1–26), fader (−∞…+12 dB), pan, mute and solo, plus 7 pre-fader **aux sends** (pick "Aux k" at the top). Master mix = DICE mixer outputs 1/2, aux k = outputs 2k+1/2k+2. |
| **Router** | Three views: **output pairs** (like the original), **every output channel** (analog 1–8, S/PDIF coax and optical, ADAT A/B 1–8), and **computer inputs 1–26** (what each Core Audio input records). Any source works: software returns 1–26, mixer master and aux outputs, analog, ADAT A/B, and coax or optical S/PDIF. "Load from ProFire" takes over the device's active routing. Changes apply to both the 44.1/48 and 88.2/96 kHz configurations. |
| **Hardware** | Device identity (model, GUID, DICE interface version, editable nickname), sample rate (through Core Audio), clock source (Internal, S/PDIF coax, Optical A/B, Word Clock), lock indicators for each external input, optical port B mode (ADAT or optical S/PDIF), which output pairs the master volume knob controls, standalone clock source and sample rate, **Save Settings to ProFire** (flash), **Reload from ProFire's Memory**, **presets** (save or load JSON files), and a factory reset of the mixer and routing. |
| **Meters** | Live levels for all inputs, software returns and hardware outputs, from the DICE router's peak meters. |
| **Advanced** | The active router table with names, raw entries and live levels; DICE register read/write with quick addresses for every section; EAP commands (load router or stream config, load or store flash, any opcode). |
| **Driver** | Install, update or uninstall the driver, plus connection status. |

The mixer and router settings live in the app and are pushed to the ProFire when the app connects, the way M-Audio's agent restored them. The ProFire boots with a muted mixer. Routes to the computer inputs aren't touched.

**Under the hood:** the dext's `ProFireUserClient` (`IOServiceOpen` type `0xFD000000`) provides info, DICE read/write (block transfers, with a quadlet fallback for regions like the mixer that don't take block reads) and EAP commands. `tools/pfreg` exposes the same from the command line:

```bash
build/pfreg read 0xE0200D24 64     # current low-rate router (count + entries)
build/pfreg write 0xE0200068 0x4000
build/pfreg eap 0x10001             # LD_ROUTER, low rates
```

Measured device facts, used by the app:
- **Optical port B is one port with two modes.** Routing anything to the S/PDIF-optical transmitter (AES1, channels 3/4) while the port is in ADAT mode corrupts the ADAT B *input*: measured as bursts of silence. The app removes the inactive side's routes, so in ADAT mode there are no AES1 destinations, and in S/PDIF mode there are no ADAT B outputs. Switching the mode re-applies the router.
- **Mixer:** 18 inputs × 16 outputs. Coefficient `(out, in)` is at mixer quadlet `1 + out·18 + in`, linear 16-bit, `0x4000` = 0 dB, `0xFFFF` ≈ +12 dB. The mixer region rejects block reads.
- **Router entries:** `(source << 8) | destination`, each byte `block << 4 | channel`. Blocks: AES 0, ADAT 1, mixer 2 (mixer inputs 2/3 as destinations), analog InS1 5, FireWire streams 0xB/0xC, mute 0xF.
- **Peak meters:** bits 27:16 of each peak entry are a 12-bit linear level for that route.
- **Application space quadlet 0:** bits 0–3 = master volume knob pairs, bit 28 = optical port B in S/PDIF mode.
- **Launching for tests:** use `open -n --stdout file /Applications/ProFireLoader.app --args --selftest` (or `--tab N --snapshot file.png`). If you exec the binary directly from a shell, the app runs but creates no window, so those hooks never fire.
- **Self-test:** `ProFireLoader --selftest` routes ADAT B In 1 → mixer ch 1 (−6 dB) → Mixer Master → ADAT A Out 3/4, and Computer In 26 ← ADAT B In 1. With the optical loop and a −12 dBFS tone on output 11, inputs 21/22 read −18.0 dBFS and input 26 reads −12.0 dBFS. That verifies source selection, coefficients, pan law, output routing and computer-input routing. Settings are restored afterwards.

## How it works

| File | Role |
|---|---|
| `ProFireOHCI/FWController.*` | OHCI bring-up, bus resets/self-IDs, config ROM, async read/write/lock (32/64-bit compare-swap), physical-DMA notifications |
| `ProFireOHCI/Dice.*`, `DiceRegs.h` | DICE ownership, clock select, stream formats, IRM channel/bandwidth allocation, EAP router + stream config load |
| `ProFireOHCI/Amdtp.*` | IR/IT DMA rings (packet-per-buffer, 256 packets each), AM824 encode/decode, timestamps |
| `ProFireOHCI/ProFireOHCI.*` | `IOUserAudioDriver`: discovery, Core Audio device, start/stop, rate changes, developer commands |
| `ProFireOHCI/ProFireAudioDevice.*` | `IOUserAudioDevice` subclass forwarding StartIO/StopIO/rate changes |
| `ProFireLoader/` | **ProFire Control** app: mixer, router, hardware settings, meters, driver install (`--activate` / `--deactivate`) |
| `ProFireOHCI/ProFireUserClient.*` | control-panel user client (DICE read/write, EAP commands) |
| `tools/pfreg.swift` | raw DICE register access from the command line |
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
- **Optical S/PDIF:** port IDs are assumed to be AES1 (channels 3/4) by DICE convention and haven't been verified with a cable.
- **Control panel not yet verified with external clocks:** S/PDIF, ADAT and word clock haven't been tested as clock sources, and optical S/PDIF output routing at port B is unverified.

## Reference material

`reference/m-audio-2.4.4/` (gitignored, M-Audio's copyright) has the original 2.4.4 kext,
the mixer app's device descriptions, and the 2626 firmware image. Useful external references:
Linux `sound/firewire/dice/*` and FFADO `src/dice/` (including `src/dice/maudio/profire_2626.*`).

## Uninstall

```bash
open /Applications/ProFireLoader.app --args --deactivate
```
