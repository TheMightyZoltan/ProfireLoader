//
//  ProFireUserClient.cpp
//

#include <DriverKit/IOLib.h>
#include <DriverKit/OSData.h>
#include <DriverKit/IOUserClient.h>
#include "ProFireUserClient.h"
#include "ProFireOHCI.h"
#include "Common.h"

struct ProFireUserClient_IVars {
    ProFireOHCI *driver = nullptr;
};

bool ProFireUserClient::init()
{
    if (!super::init()) return false;
    ivars = IONewZero(ProFireUserClient_IVars, 1);
    return ivars != nullptr;
}

void ProFireUserClient::free()
{
    IOSafeDeleteNULL(ivars, ProFireUserClient_IVars, 1);
    super::free();
}

kern_return_t IMPL(ProFireUserClient, Start)
{
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) return ret;
    ivars->driver = OSDynamicCast(ProFireOHCI, provider);
    if (!ivars->driver) return kIOReturnNoDevice;
    LOG("control client connected");
    return kIOReturnSuccess;
}

kern_return_t IMPL(ProFireUserClient, Stop)
{
    LOG("control client disconnected");
    return Stop(provider, SUPERDISPATCH);
}

kern_return_t ProFireUserClient::ExternalMethod(uint64_t selector, IOUserClientMethodArguments *a,
                                                const IOUserClientMethodDispatch *, OSObject *, void *)
{
    ProFireOHCI *d = ivars->driver;
    if (!d) return kIOReturnNotAttached;

    switch (selector) {
    case 0: {   // info
        uint64_t info[8] = {};
        d->ControlInfo(info, 8);
        uint32_t n = a->scalarOutputCount < 8 ? a->scalarOutputCount : 8;
        for (uint32_t i = 0; i < n; i++) a->scalarOutput[i] = info[i];
        a->scalarOutputCount = n;
        return kIOReturnSuccess;
    }
    case 1: {   // read
        if (a->scalarInputCount < 2) return kIOReturnBadArgument;
        uint32_t lo = uint32_t(a->scalarInput[0]), bytes = uint32_t(a->scalarInput[1]);
        if (bytes == 0 || bytes > 4096 || (bytes & 3)) return kIOReturnBadArgument;
        uint8_t *buf = static_cast<uint8_t *>(IOMallocZero(bytes));
        if (!buf) return kIOReturnNoMemory;
        kern_return_t r = d->ControlRead(lo, buf, bytes);
        if (r == kIOReturnSuccess) a->structureOutput = OSData::withBytes(buf, bytes);
        IOFree(buf, bytes);
        return r;
    }
    case 2: {   // write
        if (a->scalarInputCount < 1 || !a->structureInput) return kIOReturnBadArgument;
        uint32_t lo = uint32_t(a->scalarInput[0]);
        uint32_t bytes = uint32_t(a->structureInput->getLength());
        if (bytes == 0 || bytes > 4096 || (bytes & 3)) return kIOReturnBadArgument;
        return d->ControlWrite(lo, static_cast<const uint8_t *>(a->structureInput->getBytesNoCopy()), bytes);
    }
    case 3: {   // eap command
        if (a->scalarInputCount < 1) return kIOReturnBadArgument;
        bool ok = d->ControlEAP(uint32_t(a->scalarInput[0]));
        if (a->scalarOutputCount >= 1) { a->scalarOutput[0] = ok ? 1 : 0; a->scalarOutputCount = 1; }
        return kIOReturnSuccess;
    }
    default:
        return kIOReturnBadArgument;
    }
}
