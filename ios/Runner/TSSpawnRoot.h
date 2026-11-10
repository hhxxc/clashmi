#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Spawns an executable as root via TrollStore's persona mechanism.
/// Requires the com.apple.private.persona-mgmt entitlement and the binary
/// to be listed in the app Info.plist TSRootBinaries array.
///
/// Returns the spawned pid, or -1 on failure.
int TSSpawnRoot(NSString *path, NSArray<NSString *> *args);

/// Convenience: spawn and wait briefly for the pidfile to appear.
/// Returns YES once the pidfile exists (process wrote it at startup).
BOOL TSSpawnRootAndWaitForPidFile(NSString *path, NSArray<NSString *> *args,
                                  NSString *pidFile, NSTimeInterval timeout);

NS_ASSUME_NONNULL_END
