#import "ExceptionGuard.h"

NSString * _Nullable IDRunCatchingException(void (^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        NSString *name = exception.name ?: @"NSException";
        NSString *reason = exception.reason ?: @"";
        return [NSString stringWithFormat:@"%@: %@", name, reason];
    }
}
