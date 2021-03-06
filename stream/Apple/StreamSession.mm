/*
 
 Video Core
 Copyright (c) 2014 James G. Hurley
 
 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:
 
 The above copyright notice and this permission notice shall be included in
 all copies or substantial portions of the Software.
 
 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 THE SOFTWARE.
 
 */
#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#include <iostream>
#include <videocore/stream/Apple/StreamSession.h>

#include <sys/socket.h>
#include <sys/types.h>
#include <sys/ioctl.h>

#include <netinet/in.h>
#include <netinet/tcp.h>
#define SCB(x) ((NSStreamCallback*)(x))
#define NSIS(x) ((NSInputStream*)(x))
#define NSOS(x) ((NSOutputStream*)(x))
#define NSRL(x) ((NSRunLoop*)(x))

@interface NSStreamCallback : NSObject<NSStreamDelegate>
@property (nonatomic, assign) videocore::Apple::StreamSession* session;
@end

@implementation NSStreamCallback

- (void) stream:(NSStream *)aStream handleEvent:(NSStreamEvent)eventCode
{
    self.session->nsStreamCallback(aStream,static_cast<unsigned>( eventCode ));
}

@end
namespace videocore {
    namespace Apple {
        
        StreamSession::StreamSession() : m_status(0)
        {
            m_streamCallback = [[NSStreamCallback alloc] init];
            SCB(m_streamCallback).session = this;
        }
        
        StreamSession::~StreamSession()
        {
            disconnect();
            [SCB(m_streamCallback) release];
        }
        
        void
        StreamSession::connect(std::string host, int port, StreamSessionCallback_t callback)
        {
            m_callback = callback;
            if(m_status > 0) {
                disconnect();
            }
            @autoreleasepool {
                
                CFReadStreamRef readStream;
                CFWriteStreamRef writeStream;

                CFStreamCreatePairWithSocketToHost(kCFAllocatorDefault, (CFStringRef)[NSString stringWithUTF8String:host.c_str()], port, &readStream, &writeStream);
            
                m_inputStream = (NSInputStream*)readStream;
                m_outputStream = (NSOutputStream*)writeStream;
            

                dispatch_queue_t queue = dispatch_queue_create("com.videocore.network", 0);
                
                dispatch_async(queue, ^{
                    this->startNetwork();
                });
            }

        }
        
        void
        StreamSession::disconnect()
        {
            [NSIS(m_inputStream) close];
            [NSOS(m_outputStream) close];
            [NSIS(m_inputStream) release];
            [NSOS(m_outputStream) release];
            CFRunLoopStop([NSRL(m_runLoop) getCFRunLoop]);
        }
        int
        StreamSession::unsent()
        {
            return 0;
        }
        int
        StreamSession::unread()
        {
            int unread = 0;
            
            return unread;
        }
        size_t
        StreamSession::write(uint8_t *buffer, size_t size)
        {
            NSInteger ret = 0;
          
            if( NSOS(m_outputStream).hasSpaceAvailable ) {
                ret = [NSOS(m_outputStream) write:buffer maxLength:size];
            }
            if(ret >= 0 && ret < size && (m_status & kStreamStatusWriteBufferHasSpace)) {
                // Remove the Has Space Available flag
                m_status ^= kStreamStatusWriteBufferHasSpace;
            }
            else if (ret < 0) {
                DLog("ERROR! [%ld] buffer: %p [ 0x%02x ], size: %zu\n", (long)NSOS(m_outputStream).streamError.code, buffer, buffer[0], size);
            }

            return ret;
        }
        
        size_t
        StreamSession::read(uint8_t *buffer, size_t size)
        {
            size_t ret = 0;
            
            ret = [NSIS(m_inputStream) read:buffer maxLength:size];
            
            if((ret < size) && (m_status & kStreamStatusReadBufferHasBytes)) {
                m_status ^= kStreamStatusReadBufferHasBytes;
            }
            return ret;
        }
        
        void
        StreamSession::setStatus(StreamStatus_t status, bool clear)
        {
            if(clear) {
                m_status = status;
            } else {
                m_status |= status;
            }
            m_callback(*this, status);
        }
        void
        StreamSession::nsStreamCallback(void* stream, unsigned event)
        {
            if(event & NSStreamEventOpenCompleted) {
                
                if(NSIS(m_inputStream).streamStatus > 0 &&
                   NSOS(m_outputStream).streamStatus > 0 &&
                   NSIS(m_inputStream).streamStatus < 5 &&
                   NSOS(m_outputStream).streamStatus < 5) {
                    // Connected.
                    CFDataRef nativeSocket = (CFDataRef)CFWriteStreamCopyProperty((CFWriteStreamRef)m_outputStream, kCFStreamPropertySocketNativeHandle);
                    CFSocketNativeHandle *sock = (CFSocketNativeHandle *)CFDataGetBytePtr(nativeSocket);
                    m_outSocket = *sock;
                    int v = 1;
                    setsockopt(*sock, IPPROTO_TCP, TCP_NODELAY, &v, sizeof(int));
                    v = 0;
                    setsockopt(*sock, SOL_SOCKET, SO_SNDBUF, &v, sizeof(int));
                    CFRelease(nativeSocket);

                    setStatus(kStreamStatusConnected, true);
                } else return;
            }
            if(event & NSStreamEventHasBytesAvailable) {
                setStatus(kStreamStatusReadBufferHasBytes);
            }
            if(event & NSStreamEventHasSpaceAvailable) {
                setStatus(kStreamStatusWriteBufferHasSpace);
            }
            if(event & NSStreamEventEndEncountered) {
                setStatus(kStreamStatusEndStream, true);
            }
            if(event & NSStreamEventErrorOccurred) {
                setStatus(kStreamStatusErrorEncountered, true);
                NSLog(@"Status: %d\n", (int)((NSStream*)stream).streamStatus);
                NSLog(@"Error: %@", ((NSStream*)stream).streamError);
            }
        }
        
        void
        StreamSession::startNetwork()
        {
            m_runLoop = [NSRunLoop currentRunLoop];
            [NSIS(m_inputStream) setDelegate:SCB(m_streamCallback)];
            [NSIS(m_inputStream) scheduleInRunLoop:NSRL(m_runLoop) forMode:NSDefaultRunLoopMode];
            [NSOS(m_outputStream) setDelegate:SCB(m_streamCallback)];
            [NSOS(m_outputStream) scheduleInRunLoop:NSRL(m_runLoop) forMode:NSDefaultRunLoopMode];
            [NSOS(m_outputStream) open];
            [NSIS(m_inputStream) open];

            [NSRL(m_runLoop) run];
        }
        
    }
}
