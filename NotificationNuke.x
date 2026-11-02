// NotificationNuke — Per-app notification sound cooldowns + regex text filters. Group chats stop dinging every message; junk reminders blocked entirely. Lock screen keeps showing them.
#import <Foundation/Foundation.h>
#import <TargetConditionals.h>

//%hook SomeClass
//- (void)someMethod {
//    NSLog(@"[NotificationNuke] someMethod");
//    %orig;
//}
//%end

%ctor {
    NSLog(@"[NotificationNuke] loaded into %@ (pid %d)",
          [NSProcessInfo processInfo].processName,
          [[NSProcessInfo processInfo] processIdentifier]);
}
