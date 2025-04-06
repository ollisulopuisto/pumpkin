#import "DaemonListener.h"
#import "TFTPPacket.h"
#import "SendXFer.h"
#import "ReceiveXFer.h"
#import "StringsAttached.h"

#include <sys/socket.h>
#include <arpa/inet.h>
#include <sys/stat.h>
#include <sys/un.h>

// Command types between PumpKIN and helper
#define CMD_HELLO 1
#define CMD_READY 2
#define CMD_CONFIG 3
#define CMD_TRANSFER_REQUEST 4
#define CMD_TRANSFER_STATUS 5
#define CMD_TRANSFER_DONE 6
#define CMD_TRANSFER_APPROVE 7
#define CMD_TRANSFER_DENY 8
#define CMD_SHUTDOWN 9

#define BUFFER_SIZE 8192

typedef struct {
    uint16_t cmd;
    uint16_t transfer_id;
    char data[BUFFER_SIZE - 4];
} ipc_message_t;

static void cbListener(CFSocketRef sockie, CFSocketCallBackType cbt, CFDataRef cba,
                      const void *cbd, void *i) {
    [(DaemonListener*)i callbackWithType:cbt addr:cba data:cbd];
}

@implementation DaemonListener

-(void)callbackWithType:(CFSocketCallBackType)t addr:(CFDataRef)a data:(const void *)d {
    switch(t) {
        case kCFSocketDataCallBack: {
            // Process incoming data from the Unix domain socket
            ipc_message_t *msg = (ipc_message_t*)d;
            
            switch(msg->cmd) {
                case CMD_READY: {
                    [pumpkin log:@"TFTP helper reported ready: %s", msg->data];
                    
                    // Send configuration
                    [self sendConfiguration];
                    break;
                }
                    
                case CMD_TRANSFER_REQUEST: {
                    // Parse transfer request data
                    NSString *requestData = [NSString stringWithUTF8String:msg->data];
                    NSArray *parts = [requestData componentsSeparatedByString:@"\n"];
                    
                    if (parts.count >= 4) {
                        NSString *requestType = [parts objectAtIndex:0];
                        NSString *clientIP = [parts objectAtIndex:1];
                        NSString *filename = [parts objectAtIndex:2];
                        NSString *mode = [parts objectAtIndex:3];
                        
                        [pumpkin log:@"Transfer request: %@ for file '%@' from %@", 
                                 requestType, filename, clientIP];
                        
                        // Create a transfer object for UI display
                        [self notifyTransferRequest:msg->transfer_id
                                        requestType:requestType
                                          clientIP:clientIP
                                          filename:filename
                                              mode:mode];
                    }
                    break;
                }
                    
                case CMD_TRANSFER_STATUS: {
                    [pumpkin log:@"Transfer %d status: %s", msg->transfer_id, msg->data];
                    break;
                }
                    
                case CMD_TRANSFER_DONE: {
                    [pumpkin log:@"Transfer %d completed: %s", msg->transfer_id, msg->data];
                    break;
                }
                    
                default:
                    [pumpkin log:@"Unknown command from TFTP helper: %d", msg->cmd];
                    break;
            }
            break;
        }
            
        default:
            NSLog(@"unhandled callback: %lu", t);
            break;
    }
}

-(void)notifyTransferRequest:(uint16_t)transferId requestType:(NSString*)requestType
                   clientIP:(NSString*)clientIP filename:(NSString*)filename mode:(NSString*)mode {
    // For this simplified example, we'll auto-approve all transfers
    // In a full implementation, you would:
    // 1. Create a transfer object for UI display
    // 2. Check user preferences for auto-approval/denial
    // 3. Show a UI dialog if needed
    
    // For now, just approve all transfers
    [self sendApproveTransfer:transferId];
}

-(void)sendApproveTransfer:(uint16_t)transferId {
    ipc_message_t msg;
    msg.cmd = CMD_TRANSFER_APPROVE;
    msg.transfer_id = transferId;
    msg.data[0] = '\0';
    
    // Send the message
    NSData *data = [NSData dataWithBytes:&msg length:4 + 1]; // Just cmd + transfer_id + empty string
    CFSocketError result = CFSocketSendData(sockie, NULL, (CFDataRef)data, 0);
    
    if (result != kCFSocketSuccess) {
        [pumpkin log:@"Failed to send transfer approval: %d", result];
    }
}

-(void)sendDenyTransfer:(uint16_t)transferId {
    ipc_message_t msg;
    msg.cmd = CMD_TRANSFER_DENY;
    msg.transfer_id = transferId;
    msg.data[0] = '\0';
    
    // Send the message
    NSData *data = [NSData dataWithBytes:&msg length:4 + 1]; // Just cmd + transfer_id + empty string
    CFSocketError result = CFSocketSendData(sockie, NULL, (CFDataRef)data, 0);
    
    if (result != kCFSocketSuccess) {
        [pumpkin log:@"Failed to send transfer denial: %d", result];
    }
}

-(void)sendConfiguration {
    ipc_message_t msg;
    msg.cmd = CMD_CONFIG;
    msg.transfer_id = 0;
    
    // Send TFTP root directory
    NSString *tftpRoot = [pumpkin.theDefaults.values valueForKey:@"tftpRoot"];
    sprintf(msg.data, "tftp_root=%s", [tftpRoot UTF8String]);
    
    // Send the message
    NSData *data = [NSData dataWithBytes:&msg length:4 + strlen(msg.data) + 1];
    CFSocketError result = CFSocketSendData(sockie, NULL, (CFDataRef)data, 0);
    
    if (result != kCFSocketSuccess) {
        [pumpkin log:@"Failed to send configuration: %d", result];
    } else {
        [pumpkin log:@"Configuration sent to TFTP helper"];
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
            
            // Send hello message to initialize the connection
            ipc_message_t hello_msg;
            hello_msg.cmd = CMD_HELLO;
            hello_msg.transfer_id = 0;
            strcpy(hello_msg.data, "HELLO");
            
            NSData *data = [NSData dataWithBytes:&hello_msg length:4 + 6]; // 4 bytes header + "HELLO\0"
            CFSocketError result = CFSocketSendData(sockie, NULL, (CFDataRef)data, 0);
            
            if (result != kCFSocketSuccess) {
                [[NSException exceptionWithName:@"ConnectionFailure"
                               reason:@"Failed to send hello message to helper"
                               userInfo:nil] raise];
            }
            
            [pumpkin log:@"Hello message sent to privileged TFTP helper"];
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
        // Send shutdown command before closing
        ipc_message_t msg;
        msg.cmd = CMD_SHUTDOWN;
        msg.transfer_id = 0;
        msg.data[0] = '\0';
        
        NSData *data = [NSData dataWithBytes:&msg length:4 + 1];
        CFSocketSendData(sockie, NULL, (CFDataRef)data, 0);
        
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
