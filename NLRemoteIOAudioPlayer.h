/*
 
 Based on MixerHost. Portions copyright (C) 2010 Apple Inc. All Rights Reserved.
 
 Disclaimer: IMPORTANT:  This Apple software is supplied to you by Apple
 Inc. ("Apple") in consideration of your agreement to the following
 terms, and your use, installation, modification or redistribution of
 this Apple software constitutes acceptance of these terms.  If you do
 not agree with these terms, please do not use, install, modify or
 redistribute this Apple software.
 
 In consideration of your agreement to abide by the following terms, and
 subject to these terms, Apple grants you a personal, non-exclusive
 license, under Apple's copyrights in this original Apple software (the
 "Apple Software"), to use, reproduce, modify and redistribute the Apple
 Software, with or without modifications, in source and/or binary forms;
 provided that if you redistribute the Apple Software in its entirety and
 without modifications, you must retain this notice and the following
 text and disclaimers in all such redistributions of the Apple Software.
 Neither the name, trademarks, service marks or logos of Apple Inc. may
 be used to endorse or promote products derived from the Apple Software
 without specific prior written permission from Apple.  Except as
 expressly stated in this notice, no other rights or licenses, express or
 implied, are granted by Apple herein, including but not limited to any
 patent rights that may be infringed by your derivative works or by other
 works in which the Apple Software may be incorporated.
 
 The Apple Software is provided by Apple on an "AS IS" basis.  APPLE
 MAKES NO WARRANTIES, EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION
 THE IMPLIED WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY AND FITNESS
 FOR A PARTICULAR PURPOSE, REGARDING THE APPLE SOFTWARE OR ITS USE AND
 OPERATION ALONE OR IN COMBINATION WITH YOUR PRODUCTS.
 
 IN NO EVENT SHALL APPLE BE LIABLE FOR ANY SPECIAL, INDIRECT, INCIDENTAL
 OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 INTERRUPTION) ARISING IN ANY WAY OUT OF THE USE, REPRODUCTION,
 MODIFICATION AND/OR DISTRIBUTION OF THE APPLE SOFTWARE, HOWEVER CAUSED
 AND WHETHER UNDER THEORY OF CONTRACT, TORT (INCLUDING NEGLIGENCE),
 STRICT LIABILITY OR OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE
 POSSIBILITY OF SUCH DAMAGE.
  
 */

//
//  NLRemoteIOAudioPlayer.h
//
//  Created by Nicholas Levin on 3/31/11.
//  Copyright (c) 2010 Thames Galley Software. All rights reserved.
//

#import <AudioToolbox/AudioToolbox.h>	// for Audio Units and Extended Audio File Services APIs.
#import <CoreMedia/CMTime.h>            // for CMTime structs

#pragma mark Sound buffer structure for render callback

// Data structure for mono or stereo sound, to pass to the application's render callback function, 
//    which gets invoked by a RemoteIO unit's input bus when it needs more audio to play.
typedef struct {
    
    BOOL                            isStereo;					// set to true if there is data in the audioDataRightBuffers member
	
	UInt32                          framesPerBuffer;			// regulates how many frames we can play before moving to a new buffer
    UInt32                          readSampleNumber;			// the next audio sample to play
	UInt32                          fixedFramesForThisCallback; // temp storage to hold the number of frames requested by the AU when the callback starts
	
    AudioUnitSampleType             **audioDataLeftBuffers;     // the buffers for the left (or mono) channel of audio data read from an audio file
    AudioUnitSampleType             **audioDataRightBuffers;	// the buffers for the right channel of audio data read from an audio file
	
    unsigned char                   numBuffers;                 // the number of buffers allocated for this Rio Player
    unsigned char                   audioDataCurrentBuffer;     // the buffer that the render callback is currently reading from
    int32_t                         requestNextBuffer;			// indicates to the ring buffer selector when we need a new sample
    
	
} soundStruct, *soundStructPtr;


// As many operations need to update the UI, we have a delegate with a defined protocol
@protocol NLRemoteIOAudioPlayerDelegate

@optional
- (void) updateViewForRemoteIOAudioPlayerState;
- (void) updateViewForRemoteIOAudioPlayerDuration;
- (void) rioPlaybackDidEnd;
- (void) updateViewForRemoteIOAudioPlayerAlbumInfo;

@end


class NLRemoteIOAudioPlayer { 

private:
        
	soundStruct                     soundStructUnit;
    
	
	CFURLRef						audioFileReference;		// refers to our current audio file as indicated by readAudioFileIntoMemoryWithURL
	ExtAudioFileRef					audioFileObject;
    AudioStreamBasicDescription     streamFormat;
	AudioUnit						RioAudioPlayer;
    
	AudioBufferList*				ringBufferList;
    dispatch_queue_t                ringBufferQueue;
    dispatch_source_t               ringBufferCycle;
	
	UInt32							framesToReadFromFile;	// NOTE: Multiples of 1024 are necessary to match the AU's slices.
    UInt64                          framesRemainingInFile;
	SInt64							estimatedIterationsBeforeEOF;
    
	SInt64							extAFSOffset;			// compensating for the EAFS bug that affects AAC and Apple Lossless files 
    
    dispatch_queue_t                scrollQueue;
    uint32_t                        cancelScrollQueue;
    BOOL                            scrollingDuringPlayback;
    
    // setup functions to initialize an Audio Unit
    void                            setupAudioSession();
    void                            setupStreamFormatWithChannels(short unsigned int numChannels);
    
    // functions needed to read from a configured EAFS reference 
    void                            setCurrentBuffers(signed char requestedBuffer);
    UInt32                          readFramesFromFile(UInt32 framesToRead);
    void                            readLastSegmentOfFramesFromFile();
    
    // loads the file that this AU needs to read linear PCM data from
    void                            readAudioFileIntoMemoryWithURL(CFURLRef sourceURL);
    
    // init this Audio Unit
    void                            configureAndInitializeRioAudioPlayer();
    
    // spun off from readAudioFileIntoMemoryWithURL, as we only need to do this once and shouldn't do it when Rio is reading
    void                            allocRioAudioPlayerBuffers();
    
    // helpful debug methods
    void                            printASBD(AudioStreamBasicDescription asbd);
    void                            printErrorMessageWithStatus(const char* errorString, OSStatus result);
    
    // ring buffer methods
    void                            allocRingBufferAtPosition(SInt64 seekPosition);
    void                            initRingBuffer();
    void                            cycleRingBuffer();
    void                            playRingBufferAudio();
    
    // playback position tracking methods
    SInt64                          convertSecondsToRemoteIOSamples(float seconds);
    void                            setFramesBufferedAtSamplePosition(SInt64 position);
    void                            incrementFramesElapsed(UInt32 numSamples);
    
protected:
	    
	CMTime							framesBuffered;
	CMTime							fileDuration;

	BOOL                            playing;
    BOOL                            interruptedDuringPlayback;
	
public:
    
    NLRemoteIOAudioPlayer();
    ~NLRemoteIOAudioPlayer();
    
    id <NLRemoteIOAudioPlayerDelegate>	_delegate;					
    
    inline BOOL                     isPlaying()                                         { return playing; }
    inline BOOL                     isInterruptedDuringPlayback()                       { return interruptedDuringPlayback; }
    inline void                     setInterruptedDuringPlayback(BOOL interrupted)      { interruptedDuringPlayback = interrupted; }
    inline CMTime                   getFramesBuffered()		                            { return framesBuffered; }
    inline CMTime                   getFileDuration()                                   { return fileDuration; }
	inline float 					getFileDurationInSeconds();
    inline const soundStructPtr		getSoundStructUnitPtr()                             { return &soundStructUnit; }
    
    // starts and stops audio playback (analogous to the functions provided by play/pause buttons)
    void                            startRioAudioPlayer();
    void                            startRioAudioPlayerWithInputURL(CFURLRef path);	// used as an initializer
    void                            stopRioAudioPlayer();
    
    // seek methods
    void                            seekToPosition(float seekTime);
    
};
