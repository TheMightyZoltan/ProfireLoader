// pftest: Core Audio loopback test for the ProFire 2626 driver.
// Plays a 1 kHz sine on one output channel and reports input peak levels per channel.
//   swiftc -O -o build/pftest tools/pftest.swift
//   build/pftest [outChannel=8] [seconds=3] [dBFS=-12]
import CoreAudio
import Foundation

func prop<T>(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ value: inout T) -> OSStatus {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value)
}

func findDevice(_ name: String) -> AudioDeviceID? {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / 4)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)
    for id in ids {
        var n: Unmanaged<CFString>?
        if prop(id, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, &n) == noErr,
           let s = n?.takeRetainedValue() as String?, s.contains(name) { return id }
    }
    return nil
}

let args = CommandLine.arguments
let outCh = args.count > 1 ? Int(args[1])! : 8
let seconds = args.count > 2 ? Double(args[2])! : 3
let dbfs = args.count > 3 ? Double(args[3])! : -12
guard let dev = findDevice("ProFire 2626") else { print("ProFire 2626 not found"); exit(1) }
var rate: Float64 = 0
_ = prop(dev, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, &rate)
print("device \(dev), \(Int(rate)) Hz, tone on output \(outCh) at \(dbfs) dBFS for \(seconds) s")

final class State {
    var phase = 0.0
    var peaks = [Float](repeating: 0, count: 64)
    var callbacks = 0
    var inFrames = 0
}
let st = State()
let amp = Float(pow(10.0, dbfs / 20.0))
let w = 2.0 * Double.pi * 1000.0 / rate

var procID: AudioDeviceIOProcID?
let err = AudioDeviceCreateIOProcIDWithBlock(&procID, dev, nil) { _, inData, _, outData, _ in
    st.callbacks += 1
    let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
    for buf in inList {
        let ch = Int(buf.mNumberChannels)
        guard ch > 0, let p = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
        let frames = Int(buf.mDataByteSize) / 4 / ch
        st.inFrames += frames
        for f in 0..<frames { for c in 0..<min(ch, 64) { let v = abs(p[f * ch + c]); if v > st.peaks[c] { st.peaks[c] = v } } }
    }
    let outList = UnsafeMutableAudioBufferListPointer(outData)
    for buf in outList {
        let ch = Int(buf.mNumberChannels)
        guard ch > 0, let p = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
        let frames = Int(buf.mDataByteSize) / 4 / ch
        for f in 0..<frames {
            let s = amp * Float(sin(st.phase)); st.phase += w
            for c in 0..<ch { p[f * ch + c] = (c == outCh - 1) ? s : 0 }
        }
    }
}
guard err == noErr, let pid = procID else { print("IOProc error \(err)"); exit(1) }
let startErr = AudioDeviceStart(dev, pid)
print("AudioDeviceStart: \(startErr)")
Thread.sleep(forTimeInterval: seconds)
AudioDeviceStop(dev, pid)
AudioDeviceDestroyIOProcID(dev, pid)
print("callbacks \(st.callbacks), input frames \(st.inFrames)")
var line = ""
for c in 0..<26 {
    let p = st.peaks[c]
    let db = p > 0 ? 20 * log10(Double(p)) : -200
    line += String(format: "in%d:%.0f ", c + 1, db)
}
print("input peaks dBFS: " + line)
