#import <Foundation/Foundation.h>

NSData *URLRouterReadStatus(NSString *path, NSError **error);

@interface URLRouterStatus : NSObject
- (instancetype)initWithPath:(NSString *)path error:(NSError **)error;
- (BOOL)write:(NSDictionary *)event error:(NSError **)error;
@end
