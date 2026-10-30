#import <Foundation/Foundation.h>

BOOL URLRouterCheckABI(NSError **error);
NSString *URLRouterBuild(void);

@interface URLRouterTarget : NSObject
@property(nonatomic, readonly) NSString *applicationIdentifier;
- (instancetype)initWithPath:(NSString *)path identifier:(NSString *)identifier hash:(NSString *)hash error:(NSError **)error;
- (BOOL)unchanged;
- (BOOL)isCaller:(id)token connection:(NSXPCConnection *)connection;
- (id)detailForURL:(NSURL *)url error:(NSError **)error;
@end
