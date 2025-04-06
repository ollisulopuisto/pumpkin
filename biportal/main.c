#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <errno.h>
#include <sys/stat.h>
#include <spawn.h>
#include <sys/un.h>
#include <fcntl.h>
#include <poll.h>
#include <stdbool.h>
#include <dirent.h>
#include <signal.h>

#define SOCKET_PATH "/tmp/pumpkin_socket"
#define LOG_ERROR(fmt, ...) fprintf(stderr, "ERROR: " fmt "\n", ##__VA_ARGS__)
#define LOG_INFO(fmt, ...) fprintf(stderr, "INFO: " fmt "\n", ##__VA_ARGS__)
#define BUFFER_SIZE 8192

#define TFTP_RRQ 1
#define TFTP_WRQ 2
#define TFTP_DATA 3
#define TFTP_ACK 4
#define TFTP_ERROR 5
#define TFTP_OACK 6

// Error codes
#define TFTP_ERR_UNDEFINED 0
#define TFTP_ERR_NOT_FOUND 1
#define TFTP_ERR_ACCESS_VIOLATION 2
#define TFTP_ERR_DISK_FULL 3
#define TFTP_ERR_ILLEGAL_OP 4
#define TFTP_ERR_UNKNOWN_TID 5
#define TFTP_ERR_FILE_EXISTS 6
#define TFTP_ERR_NO_USER 7
#define TFTP_ERR_OPTION 8

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

typedef struct {
    uint16_t cmd;
    uint16_t transfer_id;
    char data[BUFFER_SIZE - 4];
} ipc_message_t;

typedef struct {
    int client_socket;
    struct sockaddr_in client_addr;
    char filename[256];
    char mode[32];
    bool is_write;
    FILE *file;
    uint16_t block;
    uint16_t transfer_id;
    time_t last_activity;
    bool waiting_approval;
    int block_size;
    bool active;
} transfer_t;

// Global variables
char tftp_root[PATH_MAX] = "/tmp";
int client_connected = 0;
int max_transfers = 20;
transfer_t transfers[20]; // Support up to 20 concurrent transfers
int next_transfer_id = 1;
bool shutdown_requested = false;

// Function prototypes
void handle_tftp_request(int sock, struct sockaddr_in *client_addr, char *buffer, int len);
void handle_ipc_message(int unix_sock, ipc_message_t *msg, size_t msg_len);
void cleanup_transfers(void);
void send_error(int sock, struct sockaddr_in *addr, int error_code, char *error_msg);
void handle_read_request(int sock, struct sockaddr_in *client_addr, char *filename, char *mode, char *options, int options_len);
void handle_write_request(int sock, struct sockaddr_in *client_addr, char *filename, char *mode, char *options, int options_len);
void process_transfer(int sock, transfer_t *transfer);
void send_ipc_message(int unix_sock, int cmd, int transfer_id, char *data);
void signal_handler(int signum);

int main(int argc, const char * argv[]) {
    // Check privileges
    if (geteuid() != 0) {
        fprintf(stderr, "This program must be run as root.\n");
        printf("%d", EPERM);
        return 1;
    }
    
    // Simple self-check mode
    if (argc == 1) {
        printf("0");
        return 0;
    }
    
    // Kill system TFTP daemon mode
    if (argc == 2 && !strcmp(argv[1], "-k")) {
        pid_t child_pid;
        int status;
        char *launchctl_args[] = {
            "/bin/launchctl", 
            "unload",
            "-w",
            "/System/Library/LaunchDaemons/tftp.plist", 
            NULL
        };
        
        status = posix_spawn(&child_pid, "/bin/launchctl", NULL, NULL, 
                           launchctl_args, NULL);
        
        if (status != 0) {
            fprintf(stderr, "posix_spawn failed: %s\n", strerror(status));
            printf("%d", status);
            return 5;
        }
        
        if (waitpid(child_pid, &status, 0) == -1) {
            fprintf(stderr, "waitpid failed: %s\n", strerror(errno));
            printf("%d", errno);
            return 6;
        }
        
        // Try alternative command if first fails
        if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
            fprintf(stderr, "First launchctl command failed, trying alternative method\n");
            
            launchctl_args[1] = "bootout";
            launchctl_args[2] = "system/com.apple.tftpd";
            launchctl_args[3] = NULL;
            
            status = posix_spawn(&child_pid, "/bin/launchctl", NULL, NULL, 
                               launchctl_args, NULL);
                               
            if (status == 0) {
                waitpid(child_pid, &status, 0);
            }
        }
        
        fprintf(stderr, "launchctl terminated with %d\n", WEXITSTATUS(status));
        return WEXITSTATUS(status);
    }
    
    // Normal server mode needs bind address and port
    if (argc != 3) {
        fprintf(stderr, "Usage: %s address port\n", argv[0]);
        return 1;
    }
    
    // Set up signal handlers
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);
    
    // Create UDP socket for TFTP
    int tftp_sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (tftp_sock < 0) {
        LOG_ERROR("Failed to create TFTP socket: %s", strerror(errno));
        return 1;
    }
    
    // Set socket options
    int optval = 1;
    if (setsockopt(tftp_sock, SOL_SOCKET, SO_REUSEADDR, &optval, sizeof(optval)) < 0) {
        LOG_ERROR("Failed to set SO_REUSEADDR: %s", strerror(errno));
    }
    
    // Bind to specified address and port
    struct sockaddr_in server_addr;
    memset(&server_addr, 0, sizeof(server_addr));
    server_addr.sin_family = AF_INET;
    server_addr.sin_addr.s_addr = inet_addr(argv[1]);
    server_addr.sin_port = htons(atoi(argv[2]));
    
    LOG_INFO("Binding to %s:%s", argv[1], argv[2]);
    if (bind(tftp_sock, (struct sockaddr*)&server_addr, sizeof(server_addr)) < 0) {
        LOG_ERROR("Failed to bind TFTP socket: %s", strerror(errno));
        close(tftp_sock);
        return 1;
    }
    
    // Create Unix domain socket for IPC with PumpKIN
    unlink(SOCKET_PATH); // Remove existing socket if present
    
    int unix_sock = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (unix_sock < 0) {
        LOG_ERROR("Failed to create Unix socket: %s", strerror(errno));
        close(tftp_sock);
        return 1;
    }
    
    struct sockaddr_un unix_addr;
    memset(&unix_addr, 0, sizeof(unix_addr));
    unix_addr.sun_family = AF_UNIX;
    strncpy(unix_addr.sun_path, SOCKET_PATH, sizeof(unix_addr.sun_path) - 1);
    
    if (bind(unix_sock, (struct sockaddr*)&unix_addr, sizeof(unix_addr)) < 0) {
        LOG_ERROR("Failed to bind Unix socket: %s", strerror(errno));
        close(tftp_sock);
        close(unix_sock);
        return 1;
    }
    
    // Set permissions for Unix socket
    chmod(SOCKET_PATH, 0666);
    
    // Initialize transfers
    memset(transfers, 0, sizeof(transfers));
    
    // Report successful startup
    printf("0\n");
    fflush(stdout);
    LOG_INFO("TFTP server started successfully");
    
    // Main loop
    struct pollfd fds[2];
    fds[0].fd = tftp_sock;
    fds[0].events = POLLIN;
    fds[1].fd = unix_sock;
    fds[1].events = POLLIN;
    
    char buffer[BUFFER_SIZE];
    
    while (!shutdown_requested) {
        // Poll for activity on both sockets
        int poll_result = poll(fds, 2, 1000); // 1-second timeout
        
        if (poll_result < 0) {
            if (errno == EINTR) continue;
            LOG_ERROR("Poll error: %s", strerror(errno));
            break;
        }
        
        // Check for TFTP packet
        if (fds[0].revents & POLLIN) {
            struct sockaddr_in client_addr;
            socklen_t addr_len = sizeof(client_addr);
            
            int bytes_received = recvfrom(tftp_sock, buffer, BUFFER_SIZE, 0,
                                         (struct sockaddr*)&client_addr, &addr_len);
            
            if (bytes_received > 0) {
                handle_tftp_request(tftp_sock, &client_addr, buffer, bytes_received);
            }
        }
        
        // Check for IPC message from PumpKIN
        if (fds[1].revents & POLLIN) {
            ipc_message_t msg;
            struct sockaddr_un from_addr;
            socklen_t from_len = sizeof(from_addr);
            
            int bytes_received = recvfrom(unix_sock, &msg, sizeof(msg), 0,
                                         (struct sockaddr*)&from_addr, &from_len);
            
            if (bytes_received > 0) {
                handle_ipc_message(unix_sock, &msg, bytes_received);
            }
        }
        
        // Process active transfers and clean up expired ones
        for (int i = 0; i < max_transfers; i++) {
            if (transfers[i].active && !transfers[i].waiting_approval) {
                process_transfer(tftp_sock, &transfers[i]);
            }
        }
        
        cleanup_transfers();
    }
    
    // Cleanup
    close(tftp_sock);
    close(unix_sock);
    unlink(SOCKET_PATH);
    
    return 0;
}

void handle_tftp_request(int sock, struct sockaddr_in *client_addr, char *buffer, int len) {
    if (len < 4) {
        LOG_ERROR("Packet too short");
        return;
    }
    
    // Extract opcode (first 2 bytes)
    uint16_t opcode = ntohs(*(uint16_t*)buffer);
    
    LOG_INFO("Received TFTP packet, opcode = %d", opcode);
    
    switch (opcode) {
        case TFTP_RRQ: {
            // Parse filename and mode
            char *filename = buffer + 2;
            int filename_len = strlen(filename);
            if (2 + filename_len + 1 >= len) {
                send_error(sock, client_addr, TFTP_ERR_ILLEGAL_OP, "Invalid RRQ format");
                return;
            }
            
            char *mode = filename + filename_len + 1;
            int mode_len = strlen(mode);
            if (2 + filename_len + 1 + mode_len + 1 > len) {
                send_error(sock, client_addr, TFTP_ERR_ILLEGAL_OP, "Invalid RRQ format");
                return;
            }
            
            // Extract options
            char *options = mode + mode_len + 1;
            int options_len = len - (2 + filename_len + 1 + mode_len + 1);
            
            LOG_INFO("RRQ: filename='%s', mode='%s'", filename, mode);
            handle_read_request(sock, client_addr, filename, mode, options, options_len);
            break;
        }
        
        case TFTP_WRQ: {
            // Parse filename and mode
            char *filename = buffer + 2;
            int filename_len = strlen(filename);
            if (2 + filename_len + 1 >= len) {
                send_error(sock, client_addr, TFTP_ERR_ILLEGAL_OP, "Invalid WRQ format");
                return;
            }
            
            char *mode = filename + filename_len + 1;
            int mode_len = strlen(mode);
            if (2 + filename_len + 1 + mode_len + 1 > len) {
                send_error(sock, client_addr, TFTP_ERR_ILLEGAL_OP, "Invalid WRQ format");
                return;
            }
            
            // Extract options
            char *options = mode + mode_len + 1;
            int options_len = len - (2 + filename_len + 1 + mode_len + 1);
            
            LOG_INFO("WRQ: filename='%s', mode='%s'", filename, mode);
            handle_write_request(sock, client_addr, filename, mode, options, options_len);
            break;
        }
        
        case TFTP_DATA:
        case TFTP_ACK:
        case TFTP_ERROR:
        case TFTP_OACK:
            // These should be handled by the transfer handlers
            LOG_INFO("Received non-request TFTP packet, ignoring at this level");
            break;
            
        default:
            LOG_ERROR("Unknown TFTP opcode: %d", opcode);
            send_error(sock, client_addr, TFTP_ERR_ILLEGAL_OP, "Unknown TFTP opcode");
            break;
    }
}

void handle_ipc_message(int unix_sock, ipc_message_t *msg, size_t msg_len) {
    if (msg_len < 4) {
        LOG_ERROR("IPC message too short");
        return;
    }
    
    uint16_t cmd = msg->cmd;
    uint16_t transfer_id = msg->transfer_id;
    
    LOG_INFO("Received IPC command: %d, transfer_id: %d", cmd, transfer_id);
    
    switch (cmd) {
        case CMD_HELLO: {
            // Client is connecting, send ready message
            send_ipc_message(unix_sock, CMD_READY, 0, "PUMPKIN_READY");
            client_connected = 1;
            LOG_INFO("PumpKIN client connected");
            break;
        }
        
        case CMD_CONFIG: {
            // Update configuration
            if (msg_len > 4) {
                // msg->data should contain configuration in format "name=value"
                char *config = msg->data;
                LOG_INFO("Received config: %s", config);
                
                // Example: parse tftp_root configuration
                if (strncmp(config, "tftp_root=", 10) == 0) {
                    strncpy(tftp_root, config + 10, sizeof(tftp_root) - 1);
                    LOG_INFO("Set TFTP root to: %s", tftp_root);
                }
            }
            break;
        }
        
        case CMD_TRANSFER_APPROVE: {
            // Find the transfer and approve it
            for (int i = 0; i < max_transfers; i++) {
                if (transfers[i].active && transfers[i].transfer_id == transfer_id) {
                    transfers[i].waiting_approval = false;
                    LOG_INFO("Transfer %d approved", transfer_id);
                    break;
                }
            }
            break;
        }
        
        case CMD_TRANSFER_DENY: {
            // Find the transfer and deny it
            for (int i = 0; i < max_transfers; i++) {
                if (transfers[i].active && transfers[i].transfer_id == transfer_id) {
                    // Send error to client
                    send_error(transfers[i].client_socket, &transfers[i].client_addr, 
                              TFTP_ERR_ACCESS_VIOLATION, "Transfer denied by user");
                    
                    // Clean up transfer
                    if (transfers[i].file) {
                        fclose(transfers[i].file);
                    }
                    transfers[i].active = false;
                    LOG_INFO("Transfer %d denied", transfer_id);
                    break;
                }
            }
            break;
        }
        
        case CMD_SHUTDOWN: {
            // Shutdown the server
            LOG_INFO("Shutdown requested by PumpKIN");
            shutdown_requested = true;
            break;
        }
        
        default:
            LOG_ERROR("Unknown IPC command: %d", cmd);
            break;
    }
}

void cleanup_transfers(void) {
    time_t now = time(NULL);
    
    for (int i = 0; i < max_transfers; i++) {
        if (transfers[i].active) {
            // If transfer has been inactive for more than 60 seconds, time it out
            if (now - transfers[i].last_activity > 60) {
                LOG_INFO("Transfer %d timed out", transfers[i].transfer_id);
                
                // Close file if open
                if (transfers[i].file) {
                    fclose(transfers[i].file);
                }
                
                // Send timeout notification to PumpKIN
                char msg[256];
                snprintf(msg, sizeof(msg), "Transfer timed out: %s", transfers[i].filename);
                send_ipc_message(transfers[i].client_socket, CMD_TRANSFER_DONE, 
                                transfers[i].transfer_id, msg);
                
                // Mark transfer as inactive
                transfers[i].active = false;
            }
        }
    }
}

void send_error(int sock, struct sockaddr_in *addr, int error_code, char *error_msg) {
    char buffer[BUFFER_SIZE];
    uint16_t *opcode = (uint16_t *)buffer;
    uint16_t *code = (uint16_t *)(buffer + 2);
    char *msg = buffer + 4;
    
    *opcode = htons(TFTP_ERROR);
    *code = htons(error_code);
    
    strncpy(msg, error_msg, BUFFER_SIZE - 5);
    buffer[BUFFER_SIZE - 1] = '\0';
    
    int msg_len = strlen(msg) + 1;
    int packet_len = 4 + msg_len;
    
    sendto(sock, buffer, packet_len, 0, (struct sockaddr *)addr, sizeof(*addr));
    LOG_INFO("Sent error to %s:%d - Code: %d, Msg: %s", 
             inet_ntoa(addr->sin_addr), ntohs(addr->sin_port), error_code, error_msg);
}

void handle_read_request(int sock, struct sockaddr_in *client_addr, char *filename, char *mode, char *options, int options_len) {
    // Check for directory traversal
    if (strstr(filename, "..") != NULL) {
        send_error(sock, client_addr, TFTP_ERR_ACCESS_VIOLATION, "Directory traversal not allowed");
        return;
    }
    
    // Get a free transfer slot
    int slot = -1;
    for (int i = 0; i < max_transfers; i++) {
        if (!transfers[i].active) {
            slot = i;
            break;
        }
    }
    
    if (slot == -1) {
        send_error(sock, client_addr, TFTP_ERR_UNDEFINED, "Too many concurrent transfers");
        return;
    }
    
    // Allocate a new transfer ID
    int transfer_id = next_transfer_id++;
    
    // Construct full path
    char full_path[PATH_MAX];
    snprintf(full_path, PATH_MAX, "%s/%s", tftp_root, filename);
    
    // Check if file exists and is readable
    FILE *fp = fopen(full_path, "rb");
    if (!fp) {
        send_error(sock, client_addr, TFTP_ERR_NOT_FOUND, strerror(errno));
        return;
    }
    
    // Set up transfer
    transfer_t *transfer = &transfers[slot];
    memset(transfer, 0, sizeof(transfer_t));
    
    transfer->client_socket = sock;
    memcpy(&transfer->client_addr, client_addr, sizeof(struct sockaddr_in));
    strncpy(transfer->filename, filename, sizeof(transfer->filename) - 1);
    strncpy(transfer->mode, mode, sizeof(transfer->mode) - 1);
    transfer->is_write = false;
    transfer->file = fp;
    transfer->block = 0;
    transfer->transfer_id = transfer_id;
    transfer->last_activity = time(NULL);
    transfer->block_size = 512; // Default block size
    transfer->active = true;
    
    // Parse options
    char *option = options;
    while (option < options + options_len && *option) {
        char *value = option + strlen(option) + 1;
        if (value >= options + options_len) break;
        
        LOG_INFO("Option: %s = %s", option, value);
        
        // Handle blksize option
        if (strcasecmp(option, "blksize") == 0) {
            int blksize = atoi(value);
            if (blksize >= 8 && blksize <= 65464) {
                transfer->block_size = blksize;
            }
        }
        
        option = value + strlen(value) + 1;
    }
    
    // Notify PumpKIN of new transfer request
    char msg[512];
    snprintf(msg, sizeof(msg), "RRQ\n%s\n%s\n%s", 
             inet_ntoa(client_addr->sin_addr), filename, mode);
    send_ipc_message(sock, CMD_TRANSFER_REQUEST, transfer_id, msg);
    
    // Mark as waiting for approval
    transfer->waiting_approval = true;
    
    LOG_INFO("Read request for '%s' from %s:%d, transfer_id=%d", 
             filename, inet_ntoa(client_addr->sin_addr), ntohs(client_addr->sin_port), transfer_id);
}

void handle_write_request(int sock, struct sockaddr_in *client_addr, char *filename, char *mode, char *options, int options_len) {
    // Check for directory traversal
    if (strstr(filename, "..") != NULL) {
        send_error(sock, client_addr, TFTP_ERR_ACCESS_VIOLATION, "Directory traversal not allowed");
        return;
    }
    
    // Get a free transfer slot
    int slot = -1;
    for (int i = 0; i < max_transfers; i++) {
        if (!transfers[i].active) {
            slot = i;
            break;
        }
    }
    
    if (slot == -1) {
        send_error(sock, client_addr, TFTP_ERR_UNDEFINED, "Too many concurrent transfers");
        return;
    }
    
    // Allocate a new transfer ID
    int transfer_id = next_transfer_id++;
    
    // Construct full path
    char full_path[PATH_MAX];
    snprintf(full_path, PATH_MAX, "%s/%s", tftp_root, filename);
    
    // Let PumpKIN check if we should allow this write
    transfer_t *transfer = &transfers[slot];
    memset(transfer, 0, sizeof(transfer_t));
    
    transfer->client_socket = sock;
    memcpy(&transfer->client_addr, client_addr, sizeof(struct sockaddr_in));
    strncpy(transfer->filename, filename, sizeof(transfer->filename) - 1);
    strncpy(transfer->mode, mode, sizeof(transfer->mode) - 1);
    transfer->is_write = true;
    transfer->file = NULL; // Will open on approval
    transfer->block = 0;
    transfer->transfer_id = transfer_id;
    transfer->last_activity = time(NULL);
    transfer->block_size = 512; // Default block size
    transfer->active = true;
    
    // Parse options
    char *option = options;
    while (option < options + options_len && *option) {
        char *value = option + strlen(option) + 1;
        if (value >= options + options_len) break;
        
        LOG_INFO("Option: %s = %s", option, value);
        
        // Handle blksize option
        if (strcasecmp(option, "blksize") == 0) {
            int blksize = atoi(value);
            if (blksize >= 8 && blksize <= 65464) {
                transfer->block_size = blksize;
            }
        }
        
        option = value + strlen(value) + 1;
    }
    
    // Notify PumpKIN of new transfer request
    char msg[512];
    snprintf(msg, sizeof(msg), "WRQ\n%s\n%s\n%s", 
             inet_ntoa(client_addr->sin_addr), filename, mode);
    send_ipc_message(sock, CMD_TRANSFER_REQUEST, transfer_id, msg);
    
    // Mark as waiting for approval
    transfer->waiting_approval = true;
    
    LOG_INFO("Write request for '%s' from %s:%d, transfer_id=%d", 
             filename, inet_ntoa(client_addr->sin_addr), ntohs(client_addr->sin_port), transfer_id);
}

void process_transfer(int sock, transfer_t *transfer) {
    // This function processes an active transfer
    // For simplicity, we're not implementing the actual TFTP protocol here
    // A full implementation would need to handle DATA, ACK, ERROR packets
    // as well as timeouts, retransmissions, etc.
    
    // Update last activity time
    transfer->last_activity = time(NULL);
    
    // For a real implementation, you would:
    // 1. For read transfers: send next block of data if ACK received
    // 2. For write transfers: acknowledge received data blocks
    // 3. Handle timeouts and retransmissions
    // 4. Close the transfer when complete
}

void send_ipc_message(int unix_sock, int cmd, int transfer_id, char *data) {
    ipc_message_t msg;
    msg.cmd = cmd;
    msg.transfer_id = transfer_id;
    
    if (data) {
        strncpy(msg.data, data, sizeof(msg.data) - 1);
        msg.data[sizeof(msg.data) - 1] = '\0';
    } else {
        msg.data[0] = '\0';
    }
    
    // Send to any connected client
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, SOCKET_PATH, sizeof(addr.sun_path) - 1);
    
    ssize_t sent = sendto(unix_sock, &msg, 4 + strlen(msg.data) + 1, 0,
                         (struct sockaddr*)&addr, sizeof(addr));
                         
    if (sent < 0) {
        LOG_ERROR("Failed to send IPC message: %s", strerror(errno));
    }
}

void signal_handler(int signum) {
    LOG_INFO("Received signal %d, shutting down", signum);
    shutdown_requested = true;
}