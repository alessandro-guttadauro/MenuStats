#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include "CIOKitPrivate.h"

// Private PowerUI client used by System Settings for the battery charge limit (selectors checked with the ObjC runtime).
@interface MSPowerUISmartChargeClient : NSObject
- (instancetype)initWithClientName:(NSString *)name;
- (BOOL)isMCLSupported;
- (unsigned long long)isMCLCurrentlyEnabled:(NSError **)error;
- (unsigned char)getMCLLimitWithError:(NSError **)error;
- (BOOL)setMCLLimit:(unsigned char)limit error:(NSError **)error;
- (BOOL)enableMCL:(NSError **)error;
- (BOOL)disableMCL:(NSError **)error;
@end

static MSPowerUISmartChargeClient *Client(void) {
    static MSPowerUISmartChargeClient *client;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI", RTLD_NOW)) return;
        Class cls = NSClassFromString(@"PowerUISmartChargeClient");
        SEL needed[] = { @selector(isMCLSupported), @selector(isMCLCurrentlyEnabled:), @selector(getMCLLimitWithError:),
                         @selector(setMCLLimit:error:), @selector(enableMCL:), @selector(disableMCL:) };
        for (size_t i = 0; cls && i < sizeof needed / sizeof *needed; i++) {
            if (![cls instancesRespondToSelector:needed[i]]) cls = nil;
        }
        if (cls) client = [(MSPowerUISmartChargeClient *)[cls alloc] initWithClientName:@"MenuStats"];
    });
    return client;
}

int MSChargeLimitSupported(void) {
    @autoreleasepool { return Client() && [Client() isMCLSupported] ? 1 : 0; }
}

int MSChargeLimitGet(void) {
    @autoreleasepool {
        if (!MSChargeLimitSupported()) return -1;
        NSError *error = nil;
        unsigned long long enabled = [Client() isMCLCurrentlyEnabled:&error];
        if (error) return -1;
        if (!enabled) return 100;
        unsigned char limit = [Client() getMCLLimitWithError:&error];
        return error ? -1 : limit;
    }
}

int MSChargeLimitSet(int percent) {
    @autoreleasepool {
        if (!MSChargeLimitSupported() || percent < 80 || percent > 100) return -1;
        NSError *error = nil;
        if (percent == 100) return [Client() disableMCL:&error] ? 0 : -2;
        if (![Client() setMCLLimit:(unsigned char)percent error:&error]) return -3;
        return [Client() enableMCL:&error] ? 0 : -4;
    }
}
