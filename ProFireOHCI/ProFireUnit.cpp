//
//  ProFireUnit.cpp
//

#include <DriverKit/IOLib.h>
#include "ProFireUnit.h"

kern_return_t IMPL(ProFireUnit, Start)
{
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) return ret;
    RegisterService();
    return kIOReturnSuccess;
}
