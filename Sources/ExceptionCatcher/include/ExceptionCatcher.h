#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 同步执行 block，并把 Objective-C 异常（如 AVFoundation 抛出的
/// 「Failed to create tap due to format mismatch」）转成返回值，避免进程被 terminate。
/// Swift 的 do/catch 只能接住 NSError，接不住 NSException，故用此桥接。
/// 返回 YES 表示正常执行完成；NO 表示抛了异常，`error` 会带上异常名与原因。
BOOL DBCatchException(void (NS_NOESCAPE ^block)(void),
                      NSString * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
