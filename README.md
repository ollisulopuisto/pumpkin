# PumpKIN ![logo](pumpkin.png)

[![Build & Test](https://github.com/ollisulopuisto/pumpkin/actions/workflows/build.yml/badge.svg)](https://github.com/ollisulopuisto/pumpkin/actions/workflows/build.yml)

Mac OS X TFTP client/server application (fork of http://kin.klever.net/pumpkin)
![screenshot](screenshot.png)

PumpKIN is an open source, fully functional, free TFTP server and TFTP client, which implements TFTP according to RFC1350. It also implements block size option, which allows transfer of files over 32MB, as well as transfer size and transfer timeout options described in RFC2348 and RFC2349.

The primary use of PumpKIN is maintenance of network equipment (such as router firmware upgrade) that fetches images from a TFTP server.

The main PumpKIN features are:

* Fully standard-compliant TFTP file transfer
* Unlimited simultaneous transfers both for TFTP server and client
* Support for TFTP blocksize option allows transfer of large files if both TFTP server and client support it
* Convenient GUI
* Combines TFTP server and TFTP client
* Open source for those willing to add missing features, fix bugs and examine code for potential flaws and fun
* You're free to torture it the way you want to as long as you preserve original author's credentials
* It would cost you nothing unless you're willing to monetarily express your gratitude and make a donation (yes, it means "free" or "freeware", just go and download it) -> http://kin.klever.net/pumpkin


Note that PumpKIN is not an FTP server, neither it is an FTP client, it is a TFTP server and TFTP client. TFTP is not FTP, these are different protocols. TFTP, unlike FTP, is used primarily for transferring files to and from the network equipment (e.g. your router, switch, hub, whatnot firmware upgrade or backup, or configuration backup and restore) that supports using of TFTP server for, not for general purpose serving downloadable files or retrieving files from the FTP servers around the world.

## Building on modern macOS

PumpKIN builds out of the box with the current Xcode (15/16) on macOS Sonoma
or later, on both Apple silicon and Intel Macs:

```
xcodebuild -project pumpkin.xcodeproj -scheme pumpkin -configuration Release
```

or just open `pumpkin.xcodeproj` in Xcode and press Cmd-B. A Release build
also produces a versioned DMG next to the `.app` in the build products
directory (Debug builds skip DMG creation).

The minimum deployment target is macOS 10.13.

## Testing

Unit tests live in the `pumpkinTests` target and cover the TFTP packet
encoder/decoder (`TFTPPacket`), the preferences value transformers and the
socket-address string helpers:

```
xcodebuild test -project pumpkin.xcodeproj -scheme pumpkin -destination 'platform=macOS'
```

GitHub Actions runs the build and the test suite on every push and pull
request (see `.github/workflows/build.yml`). The repository is public, so
the GitHub-hosted macOS runner costs nothing.

## Privileged ports and the biportal helper

Binding the standard TFTP port 69 requires root. The `biportal` helper is
launched with administrator privileges, binds the port and talks to the app
over a Unix domain socket at `/tmp/pumpkin_socket`.

Known limitation: `biportal`'s transfer state machine
(`process_transfer()` in `biportal/main.c`) is still a stub, so full file
transfers over privileged ports are not finished yet. Use an unprivileged
port (e.g. 6969) in the preferences for a fully working server today.
