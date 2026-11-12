#import <XCTest/XCTest.h>
#import "TFTPPacket.h"
#include <errno.h>

@interface TFTPPacketTests : XCTestCase
@end

@implementation TFTPPacketTests

- (void)testRRQRoundTrip {
    TFTPPacket *p = [TFTPPacket packetRRQWithFile:@"firmware.bin" xferType:@"octet"
                                       andOptions:@{@"blksize": @"1024", @"tsize": @"4096"}];
    XCTAssertNotNil(p);
    XCTAssertEqual(p.op, tftpOpRRQ);
    XCTAssertEqualObjects(p.rqFilename, @"firmware.bin");
    XCTAssertEqualObjects(p.rqType, @"octet");
    NSDictionary *opts = p.rqOptions;
    XCTAssertEqualObjects(opts[@"blksize"], @"1024");
    XCTAssertEqualObjects(opts[@"tsize"], @"4096");
    XCTAssertEqual(opts.count, (NSUInteger)2);
}

- (void)testWRQRoundTripWithoutOptions {
    TFTPPacket *p = [TFTPPacket packetWRQWithFile:@"config.txt" xferType:@"netascii"
                                       andOptions:@{}];
    XCTAssertEqual(p.op, tftpOpWRQ);
    XCTAssertEqualObjects(p.rqFilename, @"config.txt");
    XCTAssertEqualObjects(p.rqType, @"netascii");
    XCTAssertEqual(p.rqOptions.count, (NSUInteger)0);
}

- (void)testDataPacketRoundTrip {
    NSData *payload = [@"hello tftp" dataUsingEncoding:NSUTF8StringEncoding];
    TFTPPacket *p = [TFTPPacket packetDataWithBlock:42 andData:payload];
    XCTAssertEqual(p.op, tftpOpDATA);
    XCTAssertEqual(p.block, (uint16_t)42);
    XCTAssertEqualObjects(p.rqData, payload);
}

- (void)testAckPacketRoundTrip {
    TFTPPacket *p = [TFTPPacket packetACKWithBlock:65535];
    XCTAssertEqual(p.op, tftpOpACK);
    XCTAssertEqual(p.block, (uint16_t)65535);
    XCTAssertEqual(p.data.length, (NSUInteger)4);
}

- (void)testErrorPacketRoundTrip {
    TFTPPacket *p = [TFTPPacket packetErrorWithCode:tftpErrFileExists andMessage:@"already there"];
    XCTAssertEqual(p.op, tftpOpERROR);
    XCTAssertEqual(p.rqCode, (uint16_t)tftpErrFileExists);
    XCTAssertEqualObjects(p.rqMessage, @"already there");
}

- (void)testErrorPacketFromErrno {
    XCTAssertEqual([TFTPPacket packetErrorWithErrno:EACCES andFallback:@"x"].rqCode,
                   (uint16_t)tftpErrAccessViolation);
    XCTAssertEqual([TFTPPacket packetErrorWithErrno:ENOENT andFallback:@"x"].rqCode,
                   (uint16_t)tftpErrNotFound);
    XCTAssertEqual([TFTPPacket packetErrorWithErrno:EIO andFallback:@"x"].rqCode,
                   (uint16_t)tftpErrUndefined);
}

- (void)testOACKRoundTrip {
    NSDictionary *options = @{@"blksize": @"512", @"timeout": @"3"};
    TFTPPacket *p = [TFTPPacket packetOACKWithOptions:options];
    XCTAssertEqual(p.op, tftpOpOACK);
    XCTAssertEqualObjects(p.rqOptions, options);
}

- (void)testOptionNamesAreLowercasedOnParse {
    // RRQ creation preserves the case given; parsing lowercases option names per RFC 2347 usage
    TFTPPacket *p = [TFTPPacket packetRRQWithFile:@"f" xferType:@"octet"
                                       andOptions:@{@"BLKSIZE": @"128"}];
    XCTAssertEqualObjects(p.rqOptions[@"blksize"], @"128");
}

- (void)testMalformedRRQWithoutNULReturnsNilFilename {
    // op=RRQ followed by an unterminated filename
    const char bytes[] = {0x00, 0x01, 'f', 'o', 'o'};
    TFTPPacket *p = [TFTPPacket packetWithData:[NSData dataWithBytes:bytes length:sizeof(bytes)]];
    XCTAssertEqual(p.op, tftpOpRRQ);
    XCTAssertNil(p.rqFilename);
    XCTAssertNil(p.rqType);
}

- (void)testMalformedRRQWithUnterminatedTypeReturnsNilType {
    // op=RRQ, NUL-terminated filename, unterminated type
    const char bytes[] = {0x00, 0x01, 'f', 0x00, 'o', 'c'};
    TFTPPacket *p = [TFTPPacket packetWithData:[NSData dataWithBytes:bytes length:sizeof(bytes)]];
    XCTAssertEqualObjects(p.rqFilename, @"f");
    XCTAssertNil(p.rqType);
}

- (void)testNonASCIIFilenameSurvivesRoundTrip {
    TFTPPacket *p = [TFTPPacket packetRRQWithFile:@"p\u00e5\u00e5.bin" xferType:@"octet"
                                       andOptions:@{}];
    XCTAssertEqualObjects(p.rqFilename, @"p\u00e5\u00e5.bin");
}

@end
