#import "ExceptionCatcher.h"

BOOL DBCatchException(void (NS_NOESCAPE ^block)(void),
                      NSString * _Nullable * _Nullable error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            NSString *reason = exception.reason ?: @"";
            *error = [NSString stringWithFormat:@"%@: %@", exception.name, reason];
        }
        return NO;
    }
}
