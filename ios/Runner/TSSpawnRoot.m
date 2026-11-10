#import "TSSpawnRoot.h"
#include <spawn.h>

// Private spawn-persona APIs (used by TrollStore; available since iOS 12).
extern int posix_spawnattr_set_persona_np(const posix_spawnattr_t *__restrict,
                                          uid_t, uint32_t);
extern int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t *__restrict,
                                              uid_t);
extern int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t *__restrict,
                                              gid_t);
#ifndef POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE
#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 0x1000
#endif

int TSSpawnRoot(NSString *path, NSArray<NSString *> *args)
{
    NSMutableArray<NSString *> *all = [NSMutableArray arrayWithObject:path];
    if (args) {
        [all addObjectsFromArray:args];
    }

    NSUInteger count = all.count;
    char **argv = (char **)calloc(count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < count; i++) {
        argv[i] = strdup([all[i] UTF8String]);
    }
    argv[count] = NULL;

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);

    pid_t pid = 0;
    int rc = posix_spawn(&pid, [path UTF8String], &actions, &attr, argv, NULL);

    posix_spawnattr_destroy(&attr);
    posix_spawn_file_actions_destroy(&actions);
    for (NSUInteger i = 0; i < count; i++) {
        free(argv[i]);
    }
    free(argv);

    if (rc != 0) {
        NSLog(@"[TSSpawnRoot] posix_spawn failed: %d (%s)", rc, strerror(rc));
        return -1;
    }
    return (int)pid;
}

BOOL TSSpawnRootAndWaitForPidFile(NSString *path, NSArray<NSString *> *args,
                                  NSString *pidFile, NSTimeInterval timeout)
{
    if (pidFile.length == 0) {
        return TSSpawnRoot(path, args) > 0;
    }
    // Remove a stale pidfile before spawning so we never read an old one.
    [[NSFileManager defaultManager] removeItemAtPath:pidFile error:nil];

    int pid = TSSpawnRoot(path, args);
    if (pid <= 0) {
        return NO;
    }

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:pidFile]) {
            return YES;
        }
        [NSThread sleepForTimeInterval:0.05];
    }
    NSLog(@"[TSSpawnRoot] timeout waiting for pidfile %@", pidFile);
    return NO;
}
