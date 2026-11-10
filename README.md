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

By default the build signs locally (ad hoc), so no Apple Developer team is needed. The
first build will almost certainly hit some compile errors, because this code has never
been compiled. Send the error output back and it gets fixed.

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

## Known risks in this stage

- **Never compiled.** A few DriverKit API names or headers may need small fixes (`mach_timebase_info`, `GetBARInfo`, the timer clock constant).
- **Ad-hoc signing with SIP off** is how Apple documents testing without entitlements. If activation still refuses, the fallback is the boot-arg `amfi_get_out_of_my_way=1`. That loosens code-signing checks for the whole system, so only use it for testing.
- **Power-on ordering.** Switch the ProFire on before activating the driver, or switch it on afterwards and let the bus reset trigger a new scan.

## Uninstall

Click **Uninstall** in the app, or:

```bash
systemextensionsctl uninstall - local.profire.Loader.ProFireOHCI
```
