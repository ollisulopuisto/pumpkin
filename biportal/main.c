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

#define SOCKET_PATH "/tmp/pumpkin_socket"
#define LOG_ERROR(fmt, ...) fprintf(stderr, "ERROR: " fmt "\n", ##__VA_ARGS__)
#define LOG_INFO(fmt, ...) fprintf(stderr, "INFO: " fmt "\n", ##__VA_ARGS__)
#define BUFFER_SIZE 4096

// Modified forward_packets function
void forward_packets(int udp_sock, int unix_sock) {
    struct pollfd fds[2];
    char buffer[BUFFER_SIZE];
    char handshake_msg[] = "PUMPKIN_READY";
    bool client_connected = false;
    
    // Set up poll structures
    fds[0].fd = udp_sock;
    fds[0].events = POLLIN;
    fds[1].fd = unix_sock;
    fds[1].events = POLLIN;
    
    LOG_INFO("Starting packet forwarding between sockets");
    
    while (1) {
        int ret = poll(fds, 2, -1);
        if (ret < 0) {
            if (errno == EINTR) continue;
            LOG_ERROR("Poll failed: %s", strerror(errno));
            break;
        }
        
        // Unix socket activity - check if we have a client connecting
        if (fds[1].revents & POLLIN) {
            // If not yet connected with a client, check for connection
            if (!client_connected) {
                // Read the connection handshake
                char hello[20];
                struct sockaddr_un from_addr;
                socklen_t fromlen = sizeof(from_addr);
                
                // Wait for a "HELLO" message from client
                ssize_t bytes = recvfrom(unix_sock, hello, sizeof(hello), 0,
                                       (struct sockaddr*)&from_addr, &fromlen);
                
                if (bytes > 0 && strncmp(hello, "HELLO", 5) == 0) {
                    // Send our ready message back
                    sendto(unix_sock, handshake_msg, strlen(handshake_msg), 0,
                           (struct sockaddr*)&from_addr, fromlen);
                    client_connected = true;
                    LOG_INFO("Client connected to socket");
                }
            } else {
                // Handle normal packet forwarding from Unix to UDP
                ssize_t bytes = recv(unix_sock, buffer, BUFFER_SIZE, 0);
                
                if (bytes > 0) {
                    // The first part contains the destination address
                    struct sockaddr_in dest_addr;
                    if (bytes > sizeof(dest_addr)) {
                        memcpy(&dest_addr, buffer, sizeof(dest_addr));
                        
                        // Send the remaining data to the network
                        ssize_t sent = sendto(udp_sock, 
                                            buffer + sizeof(dest_addr),
                                            bytes - sizeof(dest_addr), 
                                            0, 
                                            (struct sockaddr*)&dest_addr, 
                                            sizeof(dest_addr));
                        
                        if (sent < 0) {
                            LOG_ERROR("Failed to forward to network: %s", strerror(errno));
                        }
                    }
                }
            }
        }
        
        // UDP socket activity - forward to Unix socket if client connected
        if (fds[0].revents & POLLIN && client_connected) {
            struct sockaddr_in client_addr;
            socklen_t addr_len = sizeof(client_addr);
            
            ssize_t bytes = recvfrom(udp_sock, buffer + sizeof(client_addr), 
                                      BUFFER_SIZE - sizeof(client_addr), 0, 
                                      (struct sockaddr*)&client_addr, &addr_len);
            
            if (bytes > 0) {
                LOG_INFO("Received %zd bytes from network", bytes);
                
                // Create a simple concatenated message: address + data
                memcpy(buffer, &client_addr, sizeof(client_addr));
                
                // Send to Unix socket
                ssize_t sent = send(unix_sock, buffer, bytes + sizeof(client_addr), 0);
                if (sent < 0) {
                    LOG_ERROR("Failed to forward to Unix socket: %s", strerror(errno));
                }
            }
        }
    }
}

// Main entry point - same structure as your existing code
int main(int argc, const char * argv[]) {
    // Keep existing code for checking privileges
    if (geteuid() != 0) {
        fprintf(stderr, "unprivileged\n");
        printf("%d", EPERM);
        return 1;
    }
    
    // Keep existing code for self-setup mode
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
        
        // Use posix_spawn instead of fork+exec
        status = posix_spawn(&child_pid, "/bin/launchctl", NULL, NULL, 
                           launchctl_args, NULL);
        
        if (status != 0) {
            fprintf(stderr, "posix_spawn failed: %s\n", strerror(status));
            printf("%d", status);
            return 5;
        }
        
        // Wait for the process to complete
        if (waitpid(child_pid, &status, 0) == -1) {
            fprintf(stderr, "waitpid failed: %s\n", strerror(errno));
            printf("%d", errno);
            return 6;
        }
        
        // If the first attempt fails, try the newer bootout syntax
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
    
    // Create and bind socket mode
    if (argc != 3) {
        fprintf(stderr, "Usage: %s h p\n", *argv);
        return 10;
    }
    
    // Create the UDP socket for TFTP
    int sockfd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (sockfd < 0) {
        fprintf(stderr, "Failed to create socket: %s\n", strerror(errno));
        printf("%d", errno);
        return errno;
    }
    
    struct sockaddr_in sin;
    memset(&sin, 0, sizeof(sin));
    sin.sin_family = AF_INET;
    sin.sin_len = sizeof(sin);  // Required on macOS
    sin.sin_addr.s_addr = inet_addr(argv[1]);
    sin.sin_port = htons(strtol(argv[2], NULL, 0));
    
    // Set socket options for address reuse
    int optval = 1;
    if (setsockopt(sockfd, SOL_SOCKET, SO_REUSEADDR, &optval, sizeof(optval)) < 0) {
        fprintf(stderr, "Warning: couldn't set SO_REUSEADDR: %s\n", strerror(errno));
    }
    
    // Try to bind to the socket
    LOG_INFO("Attempting to bind to %s:%s", argv[1], argv[2]);
    if (bind(sockfd, (struct sockaddr*)&sin, sizeof(sin)) < 0) {
        LOG_ERROR("Bind failed: %s (errno=%d)", strerror(errno), errno);
        printf("%d", errno);
        close(sockfd);
        return errno;
    }
    LOG_INFO("Successfully bound to %s:%s", argv[1], argv[2]);
    
    // Create a Unix domain socket for IPC
    struct sockaddr_un unix_addr;
    memset(&unix_addr, 0, sizeof(unix_addr));
    unix_addr.sun_family = AF_UNIX;
    strncpy(unix_addr.sun_path, SOCKET_PATH, sizeof(unix_addr.sun_path) - 1);
    
    // Remove existing socket if present
    unlink(SOCKET_PATH);
    
    int unix_sock = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (unix_sock < 0) {
        LOG_ERROR("Failed to create Unix domain socket: %s", strerror(errno));
        printf("%d", errno);
        close(sockfd);
        return errno;
    }
    
    if (bind(unix_sock, (struct sockaddr*)&unix_addr, sizeof(unix_addr)) < 0) {
        LOG_ERROR("Failed to bind Unix domain socket: %s", strerror(errno));
        printf("%d", errno);
        close(sockfd);
        close(unix_sock);
        return errno;
    }
    
    // Allow non-root processes to connect to our Unix socket
    chmod(SOCKET_PATH, 0666);
    
    // Send an initial handshake packet to any client that connects
    char handshake_msg[] = "PUMPKIN_READY";
    struct sockaddr_un client_addr;
    memset(&client_addr, 0, sizeof(client_addr));
    client_addr.sun_family = AF_UNIX;
    // We'll wait for a client to connect in the forward_packets loop

    // Indicate success to parent process
    printf("0\n");
    fflush(stdout);
    
    // Enter packet forwarding loop
    forward_packets(sockfd, unix_sock);
    
    // Cleanup (though we should never reach here)
    close(sockfd);
    close(unix_sock);
    unlink(SOCKET_PATH);
    return 0;
}