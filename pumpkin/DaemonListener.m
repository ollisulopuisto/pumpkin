#import "DaemonListener.h"
#import "TFTPPacket.h"
#import "SendXFer.h"
#import "ReceiveXFer.h"
#import "StringsAttached.h"

#include <sys/socket.h>
#include <arpa/inet.h>
#include <sys/stat.h>
#include <sys/un.h>

static void cbListener(CFSocketRef sockie,CFSocketCallBackType cbt,CFDataRef cba,
					   const void *cbd,void *i) {
    [(DaemonListener*)i callbackWithType:cbt addr:cba data:cbd];
}

@implementation DaemonListener

-(void)callbackWithType:(CFSocketCallBackType)t addr:(CFDataRef)a data:(const void *)d {
    switch(t) {
        case kCFSocketDataCallBack:
        {
            struct sockaddr_in *sin;
            const char *payload;
            size_t payload_len;
            
            if ([[pumpkin.theDefaults.values valueForKey:@"bindPort"] intValue] <= 1024) {
                // For privileged ports, the first sizeof(struct sockaddr_in) bytes are the client address
                sin = (struct sockaddr_in*)d;
                payload = (const char*)d + sizeof(struct sockaddr_in);
                payload_len = CFDataGetLength((CFDataRef)a) - sizeof(struct sockaddr_in);
                
                [pumpkin log:@"Received packet from %@:%d via helper", 
                         [NSString stringWithCString:inet_ntoa(sin->sin_addr) encoding:NSUTF8StringEncoding],
                         ntohs(sin->sin_port)];
            } else {
                // For non-privileged ports, use the address from the packet
                sin = (struct sockaddr_in*)CFDataGetBytePtr(a);
                payload = (const char*)d;
                payload_len = CFDataGetLength((CFDataRef)a);
            }
            
            if([pumpkin hasPeer:sin]) {
                [pumpkin log:@"I'm already processing the request from %@", 
                         [NSString stringWithSocketAddress:sin]];
                return;
            }
            
            // Create a TFTPPacket with just the payload data
            if (payload_len > 0) {
                NSData *packetData = [NSData dataWithBytes:payload length:payload_len];
                TFTPPacket *p = [TFTPPacket packetWithData:packetData];
                
                switch([p op]) {
                    case tftpOpRRQ: 
                        [pumpkin log:@"Received RRQ for file %@", p.rqFilename];
                        [[[SendXFer alloc] initWithPeer:sin andPacket:p] autorelease]; 
                        break;
                    case tftpOpWRQ: 
                        [pumpkin log:@"Received WRQ for file %@", p.rqFilename];
                        [[[ReceiveXFer alloc] initWithPeer:sin andPacket:p] autorelease]; 
                        break;
                    default:
                        [pumpkin log:@"Invalid OP %d received from %@", p.op, 
                                 [NSString stringWithSocketAddress:sin]];
                        break;
                }
            } else {
                [pumpkin log:@"Received empty packet from socket"];
            }
        }
        break;
        default:
            NSLog(@"unhandled callback: %lu", t);
            break;
    }
}

-(DaemonListener*)initWithAddress:(struct sockaddr_in*)sin {
    if(!(self=[super init])) return self;
    
    pumpkin = NSApplication.sharedApplication.delegate;

    @try {
        CFSocketContext ctx;
        ctx.version = 0;
        ctx.info = self;
        ctx.retain = 0; ctx.release = 0;
        ctx.copyDescription = 0;
        
        if(ntohs(sin->sin_port) > 1024) {
            // Can handle it ourselves for non-privileged ports
            sockie = CFSocketCreate(kCFAllocatorDefault, PF_INET, SOCK_DGRAM, IPPROTO_UDP,
                                kCFSocketReadCallBack|kCFSocketDataCallBack,
                                cbListener, &ctx);
                                
            NSData *nsd = [NSData dataWithBytes:sin length:sizeof(*sin)];
            if(CFSocketSetAddress(sockie, (CFDataRef)nsd))
                [[NSException exceptionWithName:@"BindFailure"
                                     reason:[NSString stringWithFormat:@"Binding failed, error code: %d", errno]
                                   userInfo:@{@"errno": @errno}
                  ] raise];
        } else {
            // For privileged ports (≤1024), use the helper
            const char *args[] = {
                0,
                [[NSString stringWithHostAddress:sin] UTF8String],
                [[NSString stringWithPortNumber:sin] UTF8String],
                NULL
            };
            
            [pumpkin log:@"Requesting elevated permissions to bind to port %@...", 
                     [NSString stringWithPortNumber:sin]];
            
            // Run the helper with elevated privileges
            [pumpkin runBiportal:args];
            
            // Wait a moment for the helper to set up the unix socket
            usleep(500000); // 500ms
            
            // Create socket for IPC with the helper
            int unix_sock = socket(AF_UNIX, SOCK_DGRAM, 0);
            if (unix_sock < 0) {
                [[NSException exceptionWithName:@"SocketCreationFailure"
                               reason:[NSString stringWithFormat:@"Failed to create Unix domain socket: %s", strerror(errno)]
                               userInfo:nil] raise];
            }
            
            // Connect to the Unix domain socket created by biportal
            struct sockaddr_un addr;
            memset(&addr, 0, sizeof(addr));
            addr.sun_family = AF_UNIX;
            strncpy(addr.sun_path, "/tmp/pumpkin_socket", sizeof(addr.sun_path) - 1);
            
            if (connect(unix_sock, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
                close(unix_sock);
                [[NSException exceptionWithName:@"ConnectionFailure"
                               reason:[NSString stringWithFormat:@"Failed to connect to helper: %s", strerror(errno)]
                               userInfo:nil] raise];
            }
            
            // Send a handshake to the helper and wait for response
            char hello[] = "HELLO";
            if (send(unix_sock, hello, strlen(hello), 0) < 0) {
                close(unix_sock);
                [[NSException exceptionWithName:@"ConnectionFailure"
                              reason:[NSString stringWithFormat:@"Failed to send handshake to helper: %s", strerror(errno)]
                              userInfo:nil] raise];
            }

            // Wait for response with timeout
            fd_set readfds;
            FD_ZERO(&readfds);
            FD_SET(unix_sock, &readfds);
            struct timeval tv;
            tv.tv_sec = 2;  // 2 second timeout
            tv.tv_usec = 0;

            if (select(unix_sock + 1, &readfds, NULL, NULL, &tv) <= 0) {
                close(unix_sock);
                [[NSException exceptionWithName:@"ConnectionFailure"
                              reason:@"Timeout waiting for helper response"
                              userInfo:nil] raise];
            }

            // Read response
            char response[20];
            ssize_t bytes = recv(unix_sock, response, sizeof(response) - 1, 0);
            if (bytes <= 0 || strncmp(response, "PUMPKIN_READY", 13) != 0) {
                close(unix_sock);
                [[NSException exceptionWithName:@"ConnectionFailure"
                              reason:@"Invalid response from helper"
                              userInfo:nil] raise];
            }

            [pumpkin log:@"Successfully established connection with helper"];
            
            // Create a CFSocket wrapped around our Unix domain socket
            sockie = CFSocketCreateWithNative(kCFAllocatorDefault, unix_sock, 
                                         kCFSocketReadCallBack|kCFSocketDataCallBack,
                                         cbListener, &ctx);
            
            if (!sockie) {
                close(unix_sock);
                [[NSException exceptionWithName:@"SocketCreationFailure"
                               reason:@"Failed to create CFSocket wrapper"
                               userInfo:nil] raise];
            }
            
            // Set up the socket to not close when CFSocket is invalidated since we handle that ourselves
            CFSocketSetSocketFlags(sockie, CFSocketGetSocketFlags(sockie) & ~kCFSocketCloseOnInvalidate);
            
            [pumpkin log:@"Connected to privileged port handler via Unix domain socket"];
        }
    } @catch(NSException *e) {
        if(sockie) {
            CFSocketInvalidate(sockie);
            CFRelease(sockie);
        }
        @throw;
    }

    runloopSource = CFSocketCreateRunLoopSource(kCFAllocatorDefault, sockie, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), runloopSource, kCFRunLoopDefaultMode);
    return self;
}

-(void)dealloc {
    if(runloopSource) {
	CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runloopSource, kCFRunLoopDefaultMode);
	CFRelease(runloopSource);
    }
    if(sockie) {
	CFSocketInvalidate(sockie);
	CFRelease(sockie);
    }
    [super dealloc];
}

+(DaemonListener*) listenerWithDefaults {
    struct sockaddr_in sin;
    memset(&sin,0,sizeof(sin));
    sin.sin_len=sizeof(sin);
    sin.sin_family=AF_INET;
    id d = [[NSUserDefaultsController sharedUserDefaultsController] values];
    sin.sin_port=htons([[d valueForKey:@"bindPort"] intValue]);
    sin.sin_addr.s_addr=inet_addr([[d valueForKey:@"bindAddress"] UTF8String]);
    return [[[DaemonListener alloc] initWithAddress:&sin] autorelease];
}

@end
