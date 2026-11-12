#import <XCTest/XCTest.h>
#import "StringsAttached.h"
#include <arpa/inet.h>
#include <string.h>

@interface StringsAttachedTests : XCTestCase
@end

static struct sockaddr_in makeSin(const char *ip, uint16_t port) {
    struct sockaddr_in sin;
    memset(&sin, 0, sizeof(sin));
    sin.sin_len = sizeof(sin);
    sin.sin_family = AF_INET;
    inet_aton(ip, &sin.sin_addr);
    sin.sin_port = htons(port);
    return sin;
}

@implementation StringsAttachedTests

- (void)testHostAddress {
    struct sockaddr_in sin = makeSin("127.0.0.1", 69);
    XCTAssertEqualObjects([NSString stringWithHostAddress:&sin], @"127.0.0.1");
}

- (void)testSocketAddress {
    struct sockaddr_in sin = makeSin("10.0.0.2", 6969);
    XCTAssertEqualObjects([NSString stringWithSocketAddress:&sin], @"10.0.0.2:6969");
}

- (void)testPortNumber {
    struct sockaddr_in sin = makeSin("192.168.1.1", 65535);
    XCTAssertEqualObjects([NSString stringWithPortNumber:&sin], @"65535");
}

@end
