#import <XCTest/XCTest.h>
#import "NumberTransformer.h"
#import "NSPortNumberTransformer.h"
#import "IPTransformer.h"

@interface TransformerTests : XCTestCase
@end

@implementation TransformerTests

- (void)testNumberTransformer {
    NumberTransformer *t = [[[NumberTransformer alloc] init] autorelease];
    XCTAssertEqualObjects([t transformedValue:@69], @"69");
    XCTAssertEqualObjects([t reverseTransformedValue:@"69"], @69);
    XCTAssertNil([t transformedValue:nil]);
    XCTAssertNil([t transformedValue:[NSObject new]]);
}

- (void)testPortNumberTransformerAcceptsFullPortRange {
    NSPortNumberTransformer *t = [[[NSPortNumberTransformer alloc] init] autorelease];
    XCTAssertEqualObjects([t transformedValue:@69], @"69");
    XCTAssertEqualObjects([t transformedValue:@1], @"1");
    XCTAssertEqualObjects([t transformedValue:@32768], @"32768");
    XCTAssertEqualObjects([t transformedValue:@65535], @"65535");
    XCTAssertNil([t transformedValue:@0]);
    XCTAssertNil([t transformedValue:@65536]);
    XCTAssertNil([t transformedValue:@(-1)]);
    XCTAssertEqualObjects([t reverseTransformedValue:@"8080"], @8080);
    XCTAssertNil([t reverseTransformedValue:@"70000"]);
}

- (void)testIPTransformer {
    IPTransformer *t = [[[IPTransformer alloc] init] autorelease];
    XCTAssertEqualObjects([t transformedValue:@"192.168.0.1"], @"192.168.0.1");
    XCTAssertEqualObjects([t transformedValue:@"0.0.0.0"], @"0.0.0.0");
    XCTAssertNil([t transformedValue:@"not an ip"]);
    XCTAssertNil([t transformedValue:@"999.1.1.1"]);
    XCTAssertNil([t transformedValue:nil]);
    XCTAssertEqualObjects([t reverseTransformedValue:@"10.0.0.1"], @"10.0.0.1");
}

@end
