/*
 * Force-included before every harness translation unit.
 * Imports the real system headers first (so declarations type-check), then
 * remaps every platform boundary used by 4DPlugin-Protocol.cpp to a harness
 * function/class. LaunchServices is never called (no URL scheme handler is
 * registered or changed) and no distributed notification is observed or sent.
 */
#ifndef OWNERSHIP_PLATFORM_H
#define OWNERSHIP_PLATFORM_H

#ifdef __OBJC__
#import <CoreServices/CoreServices.h>
#import <Foundation/Foundation.h>

@interface OwnershipBundle : NSBundle @end
@interface OwnershipDeniedUUID : NSUUID @end

#ifdef __cplusplus
extern "C" {
#endif
OSStatus OwnershipLSRegisterURL(CFURLRef url, Boolean update);
OSStatus OwnershipLSSetDefaultHandlerForURLScheme(CFStringRef scheme, CFStringRef bundleId);
CFNotificationCenterRef OwnershipGetDistributedCenter(void);
void OwnershipAddObserver(CFNotificationCenterRef center, const void *observer,
                          CFNotificationCallback callback, CFStringRef name,
                          const void *object, CFNotificationSuspensionBehavior behavior);
void OwnershipRemoveObserver(CFNotificationCenterRef center, const void *observer,
                             CFStringRef name, const void *object);
#ifdef __cplusplus
}
#endif

#ifndef OWNERSHIP_HOST
#define NSBundle OwnershipBundle
#define NSUUID OwnershipDeniedUUID
#define LSRegisterURL OwnershipLSRegisterURL
#define LSSetDefaultHandlerForURLScheme OwnershipLSSetDefaultHandlerForURLScheme
#define CFNotificationCenterGetDistributedCenter OwnershipGetDistributedCenter
#define CFNotificationCenterAddObserver OwnershipAddObserver
#define CFNotificationCenterRemoveObserver OwnershipRemoveObserver
#endif
#endif /* __OBJC__ */

#endif
