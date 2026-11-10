# ProFireDriver: stage 1

An experimental DriverKit driver to get the **M-Audio ProFire 2626** (TCAT DICE II,
FireWire 400) working again on Apple Silicon, where macOS no longer has a FireWire stack.

This first stage has **no audio yet**. It answers a single question: can a user-space
driver run the FireWire bus on this Mac and talk to the ProFire?

## Hardware this was written for

| Piece | Details |
|---|---|
| Mac | MacBook Pro, Apple Silicon (M1), macOS 27.0.1 |
| FireWire controller | LSI/Agere **FW643** (`11c1:5901`, rev 08), FireWire 800 OHCI, inside the **Belkin Thunderbolt Express Dock** |
| Device | M-Audio ProFire 2626, connected with a FW800 → FW400 cable |

The driver matches only the FW643 (`IOPCIMatch 0x590111c1`).

## What the driver does

1. Takes over the FW643 over PCIe (through Thunderbolt), turns on bus mastering and maps the registers.
2. Soft-resets the OHCI controller, powers up the link, and installs a minimal local config ROM, a self-ID buffer, one async-transmit context and one async-receive context.
3. Forces a bus reset and decodes the self-ID packets, which lists every node on the bus.
4. Reads each other node's config ROM with quadlet read requests and logs its GUID, vendor and model, unit directory and text descriptors.

It polls every 20 ms and uses no interrupts. Each later bus reset (for example plugging in or switching on the ProFire) triggers a new scan.

## Files

- `ProFireOHCI/ProFireOHCI.iig`, `ProFireOHCI.cpp`: the dext
- `ProFireOHCI/OHCI.h`: OHCI 1.1 register map and descriptor format
- `ProFireOHCI/Info.plist`, `ProFireOHCI.entitlements`: matching personality and DriverKit entitlements
- `ProFireLoader/`: tiny SwiftUI app that installs and uninstalls the dext
- `project.yml`: XcodeGen spec. `build.sh` generates `ProFireDriver.xcodeproj` from it and builds.

## 1. Install Xcode

Install the full Xcode from the App Store (it includes the DriverKit SDK), then:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

## 2. Build

```bash
./build.sh
```

By default the script builds unsigned and then ad-hoc signs the dext and the app with
`codesign`, so no Apple Developer team is needed. (Xcode itself refuses to ad-hoc sign the
restricted DriverKit entitlements.) The build has compiled cleanly with Xcode 27.2 and
DriverKit 27.2.

## 3. Allow an unsigned driver (testing only)

The DriverKit PCI entitlement is restricted by Apple, so for local testing:

1. Shut down. Hold the power button until "Loading startup options" appears, then choose **Options**.
2. In Recovery, open **Utilities › Terminal** and run `csrutil disable`, then restart.
3. Back in macOS:

```bash
systemextensionsctl developer on
```

To undo this later: `systemextensionsctl developer off`, then run `csrutil enable` from Recovery.

## 4. Load it and watch the log

Start the log stream in one Terminal window **first**:

```bash
log stream --level debug --predicate 'eventMessage CONTAINS "ProFireOHCI"'
```

Then:

```bash
rm -rf /Applications/ProFireLoader.app && cp -R build/Build/Products/Debug/ProFireLoader.app /Applications/ && open /Applications/ProFireLoader.app
```

Click **Install / Activate**. If macOS asks, approve the driver in **System Settings ›
General › Login Items & Extensions › Driver Extensions**.

Check that it's attached:

```bash
systemextensionsctl list
```

```bash
ioreg -l -w0 -r -n 'pci11c1,5901@0' | grep -E '\+-o|IOUserClass'
```

## What success looks like

```
ProFireOHCI: attached to PCI 11c1:5901 ...
ProFireOHCI: OHCI version 1.10 ...
ProFireOHCI: ==== bus reset: generation 1 ..., 2 self-ID quadlets ... ====
ProFireOHCI:   phy 0: link on, ... <- this Mac
ProFireOHCI:   phy 1: link on, ...
ProFireOHCI: ---- node 1 (0xffc1): reading config ROM ----
ProFireOHCI: GUID 000d6c.......  vendor OUI 0x000d6c (M-Audio)
ProFireOHCI:   Model_ID (0x17) = 0x......
...
```

If the ProFire's GUID and vendor show up, the bus, DMA through the Thunderbolt IOMMU,
and async transactions all work. Stage 2 is the DICE protocol: reading the DICE register
space, sample rate and clock, and the stream format.

## Result of the first run (2026-11-10)

It works: see [docs/stage1-first-run.log](docs/stage1-first-run.log). Highlights:

- The FW643 came up as OHCI 1.10. DMA buffers were mapped through the Thunderbolt IOMMU at `0x80000000`.
- On the first bus reset there were two nodes. The Mac's FW643 (S800) is root and cycle master, and the ProFire is a 1394a node at S400 and IRM-capable.
- The ProFire's config ROM read cleanly (31 quadlets). GUID `000d6c0404000002`, where `04` is the DICE category. Vendor "M-Audio", model `0x10` "ProFire 2626", unit spec `0x000d6c`, unit SW version `0x0100c1`.

Two fixes were needed to get here:
- **`IOPCITunnelCompatible`:** without this key, macOS won't match a driver to a PCI device that sits behind Thunderbolt (`IOPCITunnelled = Yes`).
- **`/usr/bin/log`:** zsh has a builtin called `log`, so in scripts you have to call `/usr/bin/log` explicitly.

## Stage 2a: DICE register dump (2026-11-10)

The driver now also dumps the DICE registers of any node whose GUID category is `0x04`.
The full dump is in [docs/stage2a-dice-dump.log](docs/stage2a-dice-dump.log). Highlights:

- Nickname "FW2626", DICE interface 1.0.4.0, no owner. Clock is Internal at 48 kHz, locked, and not streaming.
- **Rates:** 32k–192k.
- **Clock sources:** SPDIF, AES_ANY, ADAT, ADAT_AUX, Word Clock, ARX1/2, Internal.
- **Device → Mac (2 streams):**
  - Stream 0: Mic-Line 1–8, SPDIF L/R, plus 1 MIDI.
  - Stream 1: ADAT 1–16.
  - 26 inputs in total at 48k.
- **Mac → device (2 streams):**
  - Stream 0: Line 1–8, SPDIF L/R, plus 1 MIDI.
  - Stream 1: ADAT 1–16.
- **TCAT extension present:** router, mixer, peak meters, stream config, current config and standalone config. This is a DICE II/Jr-style device with a programmable router.

Upgrading a running dext: macOS won't stop an in-use PCI dext ("Failed to terminate dext … being replaced"). The new version takes over after a reboot, or after unplugging and replugging the Thunderbolt dock.

## Known risks in this stage

- **Compiles but has never run.** The first load on real hardware is the real test.
- **Ad-hoc signing with SIP off** is how Apple documents testing without entitlements. If activation still refuses, the fallback is the boot-arg `amfi_get_out_of_my_way=1`. That loosens code-signing checks for the whole system, so only use it for testing.
- **Power-on ordering.** Switch the ProFire on before activating the driver, or switch it on afterwards and let the bus reset trigger a new scan.

## Reference material

`reference/m-audio-2.4.4/` (gitignored, M-Audio's copyright) has M-Audio's original
kext from the Mac 2.4.4 package, the mixer app's device descriptions, and the 2626
firmware image. The kext's `Info.plist` confirms vendor `0x000D6C` and model `0x10` for
the 2626. Its class names show what the later stages need: DICE register get/set, DICE
opcodes, separate isochronous input and output programs, and a 2626-only optical port B
mode switch (ADAT vs S/PDIF).

## Uninstall

Click **Uninstall** in the app, or:

```bash
systemextensionsctl uninstall - local.profire.Loader.ProFireOHCI
```
