//
//  XMTVirtualKeyboardDevice.cpp
//
//  Build-only feasibility skeleton. See XMTVirtualKeyboardDevice.iig.
//  Nothing here sends a report, opens a device, or observes input.
//

#include <DriverKit/IOLib.h>
#include <DriverKit/OSData.h>
#include <DriverKit/OSDictionary.h>
#include <DriverKit/OSNumber.h>
#include <DriverKit/OSString.h>
#include <HIDDriverKit/IOHIDDeviceKeys.h>

#include "XMTVirtualKeyboardDevice.h"

namespace {

// Standard HID boot-protocol keyboard report descriptor: an eight byte input
// report (modifier byte, reserved byte, six key usages) and a one byte LED
// output report. Taken from the HID specification's boot keyboard, not from
// any third-party firmware project.
const uint8_t kBootKeyboardReportDescriptor[] = {
    0x05, 0x01,       // Usage Page (Generic Desktop)
    0x09, 0x06,       // Usage (Keyboard)
    0xA1, 0x01,       // Collection (Application)
    0x05, 0x07,       //   Usage Page (Keyboard/Keypad)
    0x19, 0xE0,       //   Usage Minimum (Left Control)
    0x29, 0xE7,       //   Usage Maximum (Right GUI)
    0x15, 0x00,       //   Logical Minimum (0)
    0x25, 0x01,       //   Logical Maximum (1)
    0x75, 0x01,       //   Report Size (1)
    0x95, 0x08,       //   Report Count (8)
    0x81, 0x02,       //   Input (Data, Variable, Absolute)
    0x95, 0x01,       //   Report Count (1)
    0x75, 0x08,       //   Report Size (8)
    0x81, 0x01,       //   Input (Constant)
    0x95, 0x05,       //   Report Count (5)
    0x75, 0x01,       //   Report Size (1)
    0x05, 0x08,       //   Usage Page (LEDs)
    0x19, 0x01,       //   Usage Minimum (Num Lock)
    0x29, 0x05,       //   Usage Maximum (Kana)
    0x91, 0x02,       //   Output (Data, Variable, Absolute)
    0x95, 0x01,       //   Report Count (1)
    0x75, 0x03,       //   Report Size (3)
    0x91, 0x01,       //   Output (Constant)
    0x95, 0x06,       //   Report Count (6)
    0x75, 0x08,       //   Report Size (8)
    0x15, 0x00,       //   Logical Minimum (0)
    0x25, 0x65,       //   Logical Maximum (101)
    0x05, 0x07,       //   Usage Page (Keyboard/Keypad)
    0x19, 0x00,       //   Usage Minimum (0)
    0x29, 0x65,       //   Usage Maximum (101)
    0x81, 0x00,       //   Input (Data, Array)
    0xC0              // End Collection
};

} // namespace

bool
XMTVirtualKeyboardDevice::init()
{
    return super::init();
}

void
XMTVirtualKeyboardDevice::free()
{
    super::free();
}

kern_return_t
IMPL(XMTVirtualKeyboardDevice, Start)
{
    return Start(provider, SUPERDISPATCH);
}

kern_return_t
IMPL(XMTVirtualKeyboardDevice, Stop)
{
    return Stop(provider, SUPERDISPATCH);
}

OSDictionary *
XMTVirtualKeyboardDevice::newDeviceDescription()
{
    OSDictionary * description = OSDictionary::withCapacity(4);
    if (description == nullptr) {
        return nullptr;
    }

    OSNumber * vendorID = OSNumber::withNumber(static_cast<uint64_t>(0), 32);
    OSNumber * productID = OSNumber::withNumber(static_cast<uint64_t>(0), 32);
    OSString * product = OSString::withCString("XMT Virtual Keyboard");

    if (vendorID != nullptr) {
        description->setObject(kIOHIDVendorIDKey, vendorID);
        OSSafeReleaseNULL(vendorID);
    }
    if (productID != nullptr) {
        description->setObject(kIOHIDProductIDKey, productID);
        OSSafeReleaseNULL(productID);
    }
    if (product != nullptr) {
        description->setObject(kIOHIDProductKey, product);
        OSSafeReleaseNULL(product);
    }

    return description;
}

OSData *
XMTVirtualKeyboardDevice::newReportDescriptor()
{
    return OSData::withBytes(kBootKeyboardReportDescriptor,
                             sizeof(kBootKeyboardReportDescriptor));
}
