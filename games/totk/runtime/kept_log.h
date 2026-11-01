#pragma once
/* Copies of game logs worth keeping, beside the logs: <logs>/保留的日志/<date> <why>.log. The log itself is rewritten at
   every start (the launcher keeps one previous run), so a crash or a run in which a fault guard caught something is
   lost two starts later. At most KEPT_LOG_MAX copies stay; older ones go to the Trash. Used by app/launcher.m (a crash
   found at the next start) and runtime/frontend.m (fault guards that fired, at quit). Foundation only. */
#import <Foundation/Foundation.h>

enum { KEPT_LOG_MAX = 10 };

static NSString *kept_log_dir(NSString *logs) { return [logs stringByAppendingPathComponent:@"保留的日志"]; }

/* Copies src into the kept folder under "<when> <why>.log" (when: yyyy-MM-dd HH.mm.ss of `at`, or now); returns the
   copy's path, nil if it could not be made. APFS makes the copy a clone. */
static NSString *kept_log_save(NSString *src, NSString *why, NSDate *at) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *dir = kept_log_dir(src.stringByDeletingLastPathComponent);
    if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil]) return nil;
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]; f.dateFormat = @"yyyy-MM-dd HH.mm.ss";
    NSString *dst = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@ %@.log", [f stringFromDate:at ?: [NSDate date]], why]];
    [fm removeItemAtPath:dst error:nil];
    if (![fm copyItemAtPath:src toPath:dst error:nil]) return nil;
    /* names start with the date: the oldest sort first */
    NSMutableArray<NSString *> *all = [NSMutableArray array];
    for (NSString *n in [fm contentsOfDirectoryAtPath:dir error:nil]) if ([n hasSuffix:@".log"]) [all addObject:n];
    [all sortUsingSelector:@selector(compare:)];
    for (NSUInteger i = 0; all.count - i > KEPT_LOG_MAX; i++)
        [fm trashItemAtURL:[NSURL fileURLWithPath:[dir stringByAppendingPathComponent:all[i]]] resultingItemURL:nil error:nil];
    return dst;
}
