#include "CIOKitPrivate.h"
#include <string.h>

// AppleSMC user client structures (layout must match the kernel's SMCParamStruct, 80 bytes).
typedef struct { char major, minor, build, reserved; uint16_t release; } SMCVersion;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimitData;
typedef struct { uint32_t dataSize, dataType; uint8_t dataAttributes; } SMCKeyInfo;
typedef struct {
    uint32_t key;
    SMCVersion version;
    SMCPLimitData pLimitData;
    SMCKeyInfo keyInfo;
    uint8_t result, status, data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCParam;

enum { kSMCHandleYPCEvent = 2, kSMCReadKey = 5, kSMCWriteKey = 6, kSMCGetKeyInfo = 9 };

static uint32_t SMCKeyCode(const char *key) {
    return ((uint32_t)key[0] << 24) | ((uint32_t)key[1] << 16) | ((uint32_t)key[2] << 8) | (uint32_t)key[3];
}

static kern_return_t SMCCall(io_connect_t connection, SMCParam *input, SMCParam *output) {
    size_t outputSize = sizeof(SMCParam);
    return IOConnectCallStructMethod(connection, kSMCHandleYPCEvent, input, sizeof(SMCParam), output, &outputSize);
}

io_connect_t MSSMCOpen(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return 0;
    io_connect_t connection = 0;
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, &connection);
    IOObjectRelease(service);
    return result == KERN_SUCCESS ? connection : 0;
}

void MSSMCClose(io_connect_t connection) {
    if (connection) IOServiceClose(connection);
}

int MSSMCRead(io_connect_t connection, const char *key, MSSMCValue *value) {
    if (!connection || strlen(key) != 4) return -1;
    SMCParam input = {0}, output = {0};
    input.key = SMCKeyCode(key);
    input.data8 = kSMCGetKeyInfo;
    if (SMCCall(connection, &input, &output) != KERN_SUCCESS || output.result != 0) return -1;

    uint32_t size = output.keyInfo.dataSize, type = output.keyInfo.dataType;
    memset(&input, 0, sizeof input);
    memset(&output, 0, sizeof output);
    input.key = SMCKeyCode(key);
    input.keyInfo.dataSize = size;
    input.data8 = kSMCReadKey;
    if (SMCCall(connection, &input, &output) != KERN_SUCCESS || output.result != 0) return -1;

    value->dataType = type;
    value->dataSize = size > 32 ? 32 : size;
    memcpy(value->bytes, output.bytes, value->dataSize);
    return 0;
}

int MSSMCWrite(io_connect_t connection, const char *key, const uint8_t *bytes, uint32_t size) {
    if (!connection || strlen(key) != 4 || size == 0 || size > 32) return -1;
    SMCParam input = {0}, output = {0};
    input.key = SMCKeyCode(key);
    input.data8 = kSMCGetKeyInfo;
    if (SMCCall(connection, &input, &output) != KERN_SUCCESS || output.result != 0) return -1;
    // Refuse writes whose size doesn't match the key, so a wrong type can never spill into the next field.
    if (output.keyInfo.dataSize != size) return -2;

    memset(&input, 0, sizeof input);
    memset(&output, 0, sizeof output);
    input.key = SMCKeyCode(key);
    input.keyInfo.dataSize = size;
    input.data8 = kSMCWriteKey;
    memcpy(input.bytes, bytes, size);
    kern_return_t result = SMCCall(connection, &input, &output);
    if (result != KERN_SUCCESS) return (int)result;
    return output.result == 0 ? 0 : -(int)output.result;
}
