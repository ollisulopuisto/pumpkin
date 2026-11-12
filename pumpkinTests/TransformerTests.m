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

// The app reaches port bindings through the transformer registered under the
// name the xibs use, so test that one, not a hand-built instance.
- (NSValueTransformer *)registeredPortTransformer {
    [NSPortNumberTransformer registerForPortBindings];
    NSValueTransformer *t = [NSValueTransformer valueTransformerForName:PortNumberTransformerName];
    XCTAssertTrue([t isKindOfClass:[NSPortNumberTransformer class]]);
    return t;
}

- (NSString *)transformerNameInXib:(NSString *)xibFile forKeyPath:(NSString *)keyPath {
    NSString *dir = [[[NSString stringWithUTF8String:__FILE__] stringByDeletingLastPathComponent]
                     stringByDeletingLastPathComponent];
    NSString *path = [[dir stringByAppendingPathComponent:@"pumpkin"] stringByAppendingPathComponent:xibFile];
    NSString *xml = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    XCTAssertNotNil(xml, @"cannot read %@", path);
    NSString *pat = [NSString stringWithFormat:
        @"keyPath=\"%@\"[^>]*>\\s*<dictionary key=\"options\">\\s*<string key=\"NSValueTransformerName\">(\\w+)<",
        [NSRegularExpression escapedPatternForString:keyPath]];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pat options:0 error:NULL];
    NSTextCheckingResult *m = [re firstMatchInString:xml options:0 range:NSMakeRange(0, xml.length)];
    return m ? [xml substringWithRange:[m rangeAtIndex:1]] : nil;
}

- (void)testPortBindingsInXibsUseThePortRangeTransformer {
    XCTAssertEqualObjects([self transformerNameInXib:@"ARequest.xib" forKeyPath:@"self.remotePort"],
                          PortNumberTransformerName);
    XCTAssertEqualObjects([self transformerNameInXib:@"PumpKIN.xib" forKeyPath:@"values.bindPort"],
                          PortNumberTransformerName);
}

- (void)testPortNumberTransformerAcceptsFullPortRange {
    NSValueTransformer *t = [self registeredPortTransformer];
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

// The port field's NSNumberFormatter caps what the user can type, so it must
// allow the same range as the transformer.
- (void)testServerPortFormatterAllowsTheFullPortRange {
    NSString *dir = [[[NSString stringWithUTF8String:__FILE__] stringByDeletingLastPathComponent]
                     stringByDeletingLastPathComponent];
    NSString *path = [[dir stringByAppendingPathComponent:@"pumpkin"] stringByAppendingPathComponent:@"PumpKIN.xib"];
    NSString *xml = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    XCTAssertNotNil(xml);
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:
        @"userLabel=\"Port formatter\">[^<]*(?:<(?!/numberFormatter)[^>]*>[^<]*)*?<real key=\"maximum\" value=\"(\\d+)\""
        options:0 error:NULL];
    NSTextCheckingResult *m = [re firstMatchInString:xml options:0 range:NSMakeRange(0, xml.length)];
    XCTAssertNotNil(m, @"Port formatter maximum not found in PumpKIN.xib");
    XCTAssertEqual([[xml substringWithRange:[m rangeAtIndex:1]] integerValue], 65535);
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
