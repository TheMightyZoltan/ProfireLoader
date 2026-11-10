//
//  ProFireAudioDevice.cpp
//

#include <DriverKit/IOLib.h>
#include <AudioDriverKit/AudioDriverKit.h>
#include "ProFireAudioDevice.h"
#include "ProFireOHCI.h"
#include "Common.h"

struct ProFireAudioDevice_IVars {
    ProFireOHCI *driver = nullptr;
};

bool ProFireAudioDevice::init(IOUserAudioDriver *in_driver, bool in_supports_prewarming,
                              OSString *in_device_uid, OSString *in_model_uid,
                              OSString *in_manufacturer_uid, uint32_t in_zero_timestamp_period)
{
    if (!super::init(in_driver, in_supports_prewarming, in_device_uid, in_model_uid,
                     in_manufacturer_uid, in_zero_timestamp_period)) return false;
    ivars = IONewZero(ProFireAudioDevice_IVars, 1);
    if (!ivars) return false;
    ivars->driver = OSDynamicCast(ProFireOHCI, in_driver);
    return ivars->driver != nullptr;
}

void ProFireAudioDevice::free()
{
    IOSafeDeleteNULL(ivars, ProFireAudioDevice_IVars, 1);
    super::free();
}

kern_return_t ProFireAudioDevice::StartIO(IOUserAudioStartStopFlags in_flags)
{
    LOG("Core Audio: StartIO");
    kern_return_t ret = super::StartIO(in_flags);
    if (ret != kIOReturnSuccess) return ret;
    ret = ivars->driver->StartStreaming();
    if (ret != kIOReturnSuccess) super::StopIO(in_flags);
    return ret;
}

kern_return_t ProFireAudioDevice::StopIO(IOUserAudioStartStopFlags in_flags)
{
    LOG("Core Audio: StopIO");
    ivars->driver->StopStreaming();
    return super::StopIO(in_flags);
}

kern_return_t ProFireAudioDevice::HandleChangeSampleRate(double in_sample_rate)
{
    LOG("Core Audio: change sample rate to %u", uint32_t(in_sample_rate));
    kern_return_t ret = ivars->driver->ChangeRate(in_sample_rate);
    if (ret != kIOReturnSuccess) return ret;
    return super::HandleChangeSampleRate(in_sample_rate);
}
