# Swift RTSP server

This is an RTSP server written in Swift for iOS.

The original code is based on [a server from GDCL](http://www.gdcl.co.uk/2013/02/20/iOS-Video-Encoding.html), written in 2014 and unofficially hosted at https://github.com/irons163/H264-RTSP-Server-iOS.

## Changes from the original

- Rewritten in Swift/SwiftUI
- Modernized to use Swift's `Foundation.Data` type for bit packing
- Modernized to use Swift Concurrency

**Additional features**

- Embedded (Interleaved) Binary Data ([RFC 2326, 10.12](https://datatracker.ietf.org/doc/html/rfc2326#section-10.12))
- RTCP
- Multiple sessions per client
- Audio
- New UI
- CoreGraphics based video overlay
- Camera and microphone switching
- Rotation
- Basic Auth
