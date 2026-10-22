#import "platform.h"
#import <Security/Security.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <bsm/libbsm.h>
#include <dlfcn.h>
#include <sys/stat.h>
#include <sys/sysctl.h>

@interface NSObject (URLRouterPrivate)
- (instancetype)initWithServiceType:(NSString *)type applicationIdentifier:(NSString *)identifier domain:(NSString *)domain;
- (instancetype)_initWithServiceSpecifier:(id)specifier fields:(const void *)fields;
- (instancetype)initWithBundleIdentifier:(NSString *)identifier allowPlaceholder:(BOOL)placeholder error:(NSError **)error;
- (NSString *)serviceType;
- (NSString *)bundleIdentifier;
- (id)serviceSpecifier;
- (BOOL)isApproved;
- (NSURL *)URL;
- (NSSet *)userActivityTypes;
@end

@interface NSXPCConnection (URLRouterAudit)
- (audit_token_t)auditToken;
@end

static BOOL failure(NSError **error, NSString *message) {
  if (error) *error = [NSError errorWithDomain:@"HammerspoonURLRouter" code:2
    userInfo:@{NSLocalizedDescriptionKey: message}];
  return NO;
}

NSString *URLRouterBuild(void) {
  char build[64] = {0}; size_t size = sizeof(build);
  return sysctlbyname("kern.osversion", build, &size, NULL, 0) == 0 ? @(build) : @"unknown";
}

static BOOL check(Class class, NSString *name, const char *type, NSError **error) {
  Method method = class_getInstanceMethod(class, NSSelectorFromString(name));
  if (method && strcmp(method_getTypeEncoding(method), type) == 0) return YES;
  return failure(error, [NSString stringWithFormat:@"Unsupported private API: %@.%@", class ? NSStringFromClass(class) : @"missing class", name]);
}

BOOL URLRouterCheckABI(NSError **error) {
  if (![@[@"25G83", @"26A434"] containsObject:URLRouterBuild()])
    return failure(error, @"This interception build is validated only for macOS 26.6.2 (25G83) and 27.0.1 (26A434)");
  if (!dlopen("/System/Library/PrivateFrameworks/SharedWebCredentials.framework/SharedWebCredentials", RTLD_NOW)
      || !dlopen("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/LaunchServices", RTLD_NOW))
    return failure(error, @"Could not load SharedWebCredentials and LaunchServices");
  Class specifier = NSClassFromString(@"_SWCServiceSpecifier");
  Class details = NSClassFromString(@"_SWCServiceDetails");
  Class record = NSClassFromString(@"LSApplicationRecord");
  return check(specifier, @"initWithServiceType:applicationIdentifier:domain:", "@40@0:8@16@24@32", error)
    && check(specifier, @"serviceType", "@16@0:8", error)
    && check(specifier, @"bundleIdentifier", "@16@0:8", error)
    && check(details, @"_initWithServiceSpecifier:fields:", "@32@0:8@16r^{SWCFields=b2b2b1b1b2b1b3c}24", error)
    && check(details, @"serviceSpecifier", "@16@0:8", error)
    && check(details, @"isApproved", "B16@0:8", error)
    && check(record, @"initWithBundleIdentifier:allowPlaceholder:error:", "@36@0:8@16B24^@28", error)
    && check(record, @"URL", "@16@0:8", error)
    && check(record, @"userActivityTypes", "@16@0:8", error)
    && check(NSXPCConnection.class, @"auditToken", "{?=[8I]}16@0:8", error);
}

@implementation URLRouterTarget {
  NSString *_path;
  NSString *_executable;
  NSString *_applicationIdentifier;
  SecRequirementRef _requirement;
  struct stat _stamp;
}

- (instancetype)initWithPath:(NSString *)path identifier:(NSString *)identifier hash:(NSString *)hash error:(NSError **)error {
  if (!(self = [super init])) return nil;
  _path = path.stringByResolvingSymlinksInPath;
  NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:[NSURL fileURLWithPath:
    [_path stringByAppendingPathComponent:@"Contents/Info.plist"]] error:error];
  NSString *bundle = info[@"CFBundleIdentifier"];
  NSString *executable = info[@"CFBundleExecutable"];
  NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
  if (![bundle isKindOfClass:NSString.class] || ![bundle isEqual:@"local.pandoks.HammerspoonURLRouter"]
      || ![executable isKindOfClass:NSString.class] || ![executable isEqual:@"HammerspoonURLRouter"]
      || ![identifier hasSuffix:[@"." stringByAppendingString:bundle]] || identifier.length != bundle.length + 11
      || hash.length != 40 || [hash rangeOfCharacterFromSet:hex.invertedSet].location != NSNotFound
      || ![info[@"NSUserActivityTypes"] isKindOfClass:NSArray.class]
      || ![info[@"NSUserActivityTypes"] containsObject:@"NSUserActivityTypeBrowsingWeb"]) {
    failure(error, @"Router target must have the expected bundle, executable, browsing-web activity, application identifier and code hash");
    return nil;
  }
  _executable = [[_path stringByAppendingPathComponent:@"Contents/MacOS"] stringByAppendingPathComponent:executable];
  NSString *requirement = [NSString stringWithFormat:@"cdhash H\"%@\"", hash];
  OSStatus result = SecRequirementCreateWithString((__bridge CFStringRef)requirement, kSecCSDefaultFlags, &_requirement);
  SecStaticCodeRef code = NULL;
  if (result == errSecSuccess)
    result = SecStaticCodeCreateWithPath((__bridge CFURLRef)[NSURL fileURLWithPath:_path], kSecCSDefaultFlags, &code);
  if (result == errSecSuccess)
    result = SecStaticCodeCheckValidity(code, kSecCSStrictValidate | kSecCSCheckAllArchitectures, _requirement);
  CFDictionaryRef signing = NULL;
  if (result == errSecSuccess) result = SecCodeCopySigningInformation(code, kSecCSSigningInformation, &signing);
  NSDictionary *identity = CFBridgingRelease(signing);
  if (code) CFRelease(code);
  if (result != errSecSuccess
      || ![identity[(__bridge NSString *)kSecCodeInfoEntitlementsDict][@"com.apple.application-identifier"] isEqual:identifier]
      || ![identity[(__bridge NSString *)kSecCodeInfoIdentifier] isEqual:bundle]
      || ![[identity[(__bridge NSString *)kSecCodeInfoMainExecutable] path] isEqual:_executable]
      || stat(_executable.fileSystemRepresentation, &_stamp) != 0 || !S_ISREG(_stamp.st_mode)) {
    failure(error, [NSString stringWithFormat:@"Router code identity validation failed (%d)", (int)result]);
    return nil;
  }
  id record = [[NSClassFromString(@"LSApplicationRecord") alloc] initWithBundleIdentifier:bundle allowPlaceholder:NO error:error];
  if (!record || ![[[record URL] path].stringByResolvingSymlinksInPath isEqual:_path]
      || ![[record userActivityTypes] containsObject:@"NSUserActivityTypeBrowsingWeb"]) {
    failure(error, @"LaunchServices router registration does not match the trusted path or browsing-web activity");
    return nil;
  }
  Method flags = class_getInstanceMethod([record class], NSSelectorFromString(@"_rawMoreFlags"));
  const char *type = flags ? method_getTypeEncoding(flags) : "";
  // macOS 27 adds a twentieth flag.
  if ((!strcmp(type, "{LSBundleMoreFlags=b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1}16@0:8")
       || !strcmp(type, "{LSBundleMoreFlags=b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1}16@0:8"))
      && ((uint32_t (*)(id, SEL))objc_msgSend)(record, NSSelectorFromString(@"_rawMoreFlags")) != 0) {
    failure(error, @"Router registration is ineligible for native app-link delivery");
    return nil;
  }
  _applicationIdentifier = [identifier copy];
  NSError *detailsError;
  id detail = [self detailForURL:[NSURL URLWithString:@"https://127.0.0.1/"] error:&detailsError];
  NSData *archive = detail ? [NSKeyedArchiver archivedDataWithRootObject:detail requiringSecureCoding:YES error:&detailsError] : nil;
  id decoded = archive ? [NSKeyedUnarchiver unarchivedObjectOfClass:NSClassFromString(@"_SWCServiceDetails") fromData:archive error:&detailsError] : nil;
  if (!decoded || ![decoded isApproved] || ![[[decoded serviceSpecifier] bundleIdentifier] isEqual:bundle]) {
    failure(error, detailsError.localizedDescription ?: @"Synthetic app-link failed its secure transport round trip");
    return nil;
  }
  return self;
}

- (NSString *)applicationIdentifier { return _applicationIdentifier; }

- (BOOL)unchanged {
  struct stat stamp;
  return stat(_executable.fileSystemRepresentation, &stamp) == 0
    && stamp.st_dev == _stamp.st_dev && stamp.st_ino == _stamp.st_ino && stamp.st_size == _stamp.st_size
    && stamp.st_mtimespec.tv_sec == _stamp.st_mtimespec.tv_sec && stamp.st_mtimespec.tv_nsec == _stamp.st_mtimespec.tv_nsec
    && stamp.st_ctimespec.tv_sec == _stamp.st_ctimespec.tv_sec && stamp.st_ctimespec.tv_nsec == _stamp.st_ctimespec.tv_nsec;
}

- (BOOL)verifyGuest:(NSDictionary *)attributes {
  SecCodeRef code = NULL;
  if (SecCodeCopyGuestWithAttributes(NULL, (__bridge CFDictionaryRef)attributes, kSecCSDefaultFlags, &code) != errSecSuccess) return NO;
  BOOL valid = SecCodeCheckValidity(code, kSecCSDefaultFlags, _requirement) == errSecSuccess;
  SecStaticCodeRef disk = NULL; CFDictionaryRef signing = NULL;
  if (valid) valid = SecCodeCopyStaticCode(code, kSecCSDefaultFlags, &disk) == errSecSuccess;
  if (valid) valid = SecCodeCopySigningInformation(disk, kSecCSSigningInformation, &signing) == errSecSuccess;
  NSDictionary *identity = CFBridgingRelease(signing);
  if (valid) valid = [[identity[(__bridge NSString *)kSecCodeInfoMainExecutable] path].stringByResolvingSymlinksInPath isEqual:_executable];
  if (disk) CFRelease(disk);
  CFRelease(code);
  return valid;
}

- (BOOL)isCaller:(id)token connection:(NSXPCConnection *)connection {
  if ([token isKindOfClass:NSValue.class] && strcmp([token objCType], @encode(audit_token_t)) == 0) {
    audit_token_t audit;
    [token getValue:&audit size:sizeof(audit)];
    return [self verifyGuest:@{(__bridge NSString *)kSecGuestAttributeAudit: [NSData dataWithBytes:&audit length:sizeof(audit)]}];
  }
  if (!connection) return NO;
  audit_token_t audit = connection.auditToken;
  return [self verifyGuest:@{(__bridge NSString *)kSecGuestAttributeAudit: [NSData dataWithBytes:&audit length:sizeof(audit)]}];
}

- (id)detailForURL:(NSURL *)url error:(NSError **)error {
  id specifier = [[NSClassFromString(@"_SWCServiceSpecifier") alloc] initWithServiceType:@"applinks"
    applicationIdentifier:_applicationIdentifier domain:url.host];
  const uint8_t fields[3] = {4, 0, 0};
  id detail = specifier ? [[NSClassFromString(@"_SWCServiceDetails") alloc] _initWithServiceSpecifier:specifier fields:fields] : nil;
  if (!detail || ![detail isApproved]) { failure(error, @"Could not construct an approved router app-link"); return nil; }
  return detail;
}

- (void)dealloc { if (_requirement) CFRelease(_requirement); }
@end
