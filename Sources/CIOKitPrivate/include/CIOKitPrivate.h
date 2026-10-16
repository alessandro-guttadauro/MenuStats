#pragma once

#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>

// Private IOKit HID event system API, used to read temperature sensors on Apple Silicon.
// Declared under MS* names bound to the real symbols via asm labels, so they never clash
// with the partial public declarations in IOKit's own headers.

CF_ASSUME_NONNULL_BEGIN

CFTypeRef _Nullable MSHIDClientCreate(CFAllocatorRef _Nullable allocator)
    __asm("_IOHIDEventSystemClientCreate") CF_RETURNS_RETAINED;

void MSHIDClientSetMatching(CFTypeRef client, CFDictionaryRef matching)
    __asm("_IOHIDEventSystemClientSetMatching");

CFArrayRef _Nullable MSHIDClientCopyServices(CFTypeRef client)
    __asm("_IOHIDEventSystemClientCopyServices") CF_RETURNS_RETAINED;

CFTypeRef _Nullable MSHIDServiceCopyProperty(CFTypeRef service, CFStringRef key)
    __asm("_IOHIDServiceClientCopyProperty") CF_RETURNS_RETAINED;

CFTypeRef _Nullable MSHIDServiceCopyEvent(CFTypeRef service, int64_t type, int32_t options, int64_t timestamp)
    __asm("_IOHIDServiceClientCopyEvent") CF_RETURNS_RETAINED;

double MSHIDEventGetFloatValue(CFTypeRef event, int32_t field)
    __asm("_IOHIDEventGetFloatValue");

CF_ASSUME_NONNULL_END

enum {
    MSHIDEventTypeTemperature = 15,
    MSHIDEventFieldTemperatureLevel = 15 << 16,
    MSHIDUsagePageAppleVendor = 0xff00,
    MSHIDUsageTemperatureSensor = 5,
};

// MARK: - SMC (System Management Controller), read-only access works without root.

#include <IOKit/IOKitLib.h>

typedef struct {
    uint32_t dataType;  // four-character type, e.g. 'flt ', 'ui8 '
    uint32_t dataSize;
    uint8_t bytes[32];
} MSSMCValue;

CF_ASSUME_NONNULL_BEGIN
/// Opens a connection to AppleSMC; returns 0 on failure.
io_connect_t MSSMCOpen(void);
void MSSMCClose(io_connect_t connection);
/// Reads a four-character key. Returns 0 on success.
int MSSMCRead(io_connect_t connection, const char *key, MSSMCValue *value);
/// Writes a four-character key (needs root). `size` must match the key's size. Returns 0 on success.
int MSSMCWrite(io_connect_t connection, const char *key, const uint8_t *bytes, uint32_t size);
CF_ASSUME_NONNULL_END

// MARK: - macOS charge limit (System Settings ▸ Battery ▸ Charge Limit), through the private PowerUI framework.
// Works without root on Macs and macOS versions that offer the limit; values are 80...100 (100 = no limit).

/// Returns 1 if this Mac offers the macOS charge limit.
int MSChargeLimitSupported(void);
/// Current limit in percent (100 when off), or -1 on error.
int MSChargeLimitGet(void);
/// Sets the limit (80...100; 100 turns it off). Returns 0 on success.
int MSChargeLimitSet(int percent);
