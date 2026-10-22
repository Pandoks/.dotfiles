#import <Foundation/Foundation.h>

@interface URLSelectorStore : NSObject
@property(nonatomic, readonly) NSDictionary *snapshot;
- (instancetype)initWithPath:(NSString *)path report:(void (^)(NSDictionary *))report;
- (int)classifyURL:(NSURL *)url snapshot:(NSDictionary **)snapshot;
- (void)stop;
@end
