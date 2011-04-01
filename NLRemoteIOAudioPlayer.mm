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
//  NLRemoteIOAudioPlayer.mm
//
//  Created by Nicholas Levin on 3/31/11.
//  Copyright (c) 2010 Thames Galley Software. All rights reserved.
//

#import "NLRemoteIOAudioPlayer.h"
#import <libkern/OSAtomic.h>

#pragma mark Mixer input bus render callback

//    This callback is invoked each time a Remote IO unit input bus requires more audio
//        samples. In this app, the mixer unit has two input buses. Each of them has its own render 
//        callback function and its own interleaved audio data buffer to read from.
//
//    This callback is written for an inRefCon parameter that can point to two noninterleaved 
//        buffers (for a stereo sound) or to one mono buffer (for a mono sound).
//
//    Audio unit input render callbacks are invoked on a realtime priority thread (the highest 
//    priority on the system). To work well, to not make the system unresponsive, and to avoid 
//    audio artifacts, a render callback must not:
//
//        * allocate memory
//        * access the file system or a network connection
//        * take locks
//        * waste time
//
//    In addition, it's usually best to avoid sending Objective-C messages in a render callback.
//
//    Declared as AURenderCallback in AudioUnit/AUComponent.h. See Audio Unit Component Services Reference.
static OSStatus inputRenderCallback (
									 void                        *inRefCon,     // A pointer to a struct containing the complete audio data 
																				//    to play, as well as state information such as the  
																				//    first sample to play on this invocation of the callback.
									 AudioUnitRenderActionFlags  *ioActionFlags,// Unused here. When generating audio, use ioActionFlags to indicate silence 
																				//    between sounds; for silence, also memset the ioData buffers to 0.
									 const AudioTimeStamp        *inTimeStamp,  // Unused here.
									 UInt32                      inBusNumber,   // The RemoteIO AudioPlayer input bus that is requesting some new
																				//    frames of audio data to play.
									 UInt32                      inNumberFrames,// The number of frames of audio to provide to the buffer(s)
																				//    pointed to by the ioData parameter.
									 AudioBufferList             *ioData        // On output, the audio data to play. The callback's primary 
																				//    responsibility is to fill the buffer(s) in the 
																				//    AudioBufferList.
									 ) {
    
	// Create a pointer to reference the structure that holds sample data, since we call upon it VERY frequently
    soundStructPtr soundStructDelegate = static_cast<soundStructPtr>(inRefCon);
	
    // Fill the buffer or buffers pointed at by *ioData with the requested number of samples 
    //    of audio from the sound stored in memory.
	
	// Compensating for when inNumberFrames exceeds our buffer after display sleeps (causing sleep/wake crash) - goes from 1024 to 4096
	if ((soundStructDelegate[inBusNumber].fixedFramesForThisCallback = inNumberFrames) == 4096) {
		
		// (Don't worry about hit to fps or wasting too much time now; device display is sleeping when we meet the condition above)
		
		// Check if this iteration will fall out of bounds
		if (soundStructDelegate[inBusNumber].framesPerBuffer < (soundStructDelegate[inBusNumber].readSampleNumber + inNumberFrames)) {	
			
			UInt32 frameOffset = soundStructDelegate[inBusNumber].framesPerBuffer - soundStructDelegate[inBusNumber].readSampleNumber;
			
			// Collect samples from this buffer AND the next, starting at the point where one exceeds the limits of the buffer
			
			for (UInt32 frameNumber = 0; frameNumber < frameOffset; ++frameNumber) {
				(static_cast<AudioUnitSampleType *>(ioData->mBuffers[0].mData))[frameNumber] = soundStructDelegate[inBusNumber].audioDataLeftBuffers[soundStructDelegate[inBusNumber].audioDataCurrentBuffer][soundStructDelegate[inBusNumber].readSampleNumber];
				if (soundStructDelegate[inBusNumber].isStereo) 
					(static_cast<AudioUnitSampleType *>(ioData->mBuffers[1].mData))[frameNumber] = soundStructDelegate[inBusNumber].audioDataRightBuffers[soundStructDelegate[inBusNumber].audioDataCurrentBuffer][soundStructDelegate[inBusNumber].readSampleNumber];
				
				++soundStructDelegate[inBusNumber].readSampleNumber;
			}
			
			// readSampleNumber now matches frameOffset		
			
			// Now that we have reached the last sample in this buffer...

			// Find the location of the next buffer to read audio from		
			if (++soundStructDelegate[inBusNumber].audioDataCurrentBuffer == soundStructDelegate[inBusNumber].numBuffers)
				soundStructDelegate[inBusNumber].audioDataCurrentBuffer = 0;
			
			// indirectly request that the ring buffer thread fetch another buffer with ExtAudioFileRead
			OSAtomicAdd32(1,&soundStructDelegate[inBusNumber].requestNextBuffer);

			// Now read from the next buffer
			UInt32 continueSampleNumber = 0;
			
			// Using inNumberFrames instead of fixedFramesForThisCallback here so we can bail faster if we need to provide fewer samples; avoid a skip
			for (UInt32 frameNumber = frameOffset; frameNumber < inNumberFrames; ++frameNumber) {
				(static_cast<AudioUnitSampleType *>(ioData->mBuffers[0].mData))[frameNumber] = soundStructDelegate[inBusNumber].audioDataLeftBuffers[soundStructDelegate[inBusNumber].audioDataCurrentBuffer][continueSampleNumber];
				if (soundStructDelegate[inBusNumber].isStereo)
					(static_cast<AudioUnitSampleType *>(ioData->mBuffers[1].mData))[frameNumber] = soundStructDelegate[inBusNumber].audioDataRightBuffers[soundStructDelegate[inBusNumber].audioDataCurrentBuffer][continueSampleNumber];
				
				++continueSampleNumber;
			
			}
									
			// Continue reading from where continueSampleNumber left off in the next iteration
			soundStructDelegate[inBusNumber].readSampleNumber = continueSampleNumber;
			
			// Return, and don't advance any further
			return noErr;
		}
		else {
			
			// Iterate with the flexible inNumberFrames; it's okay to drop frames from 4096 -> 1024 in the middle of a for loop. It helps us avoid an audible skip in audio playback.
			for (UInt32 frameNumber = 0; frameNumber < inNumberFrames; ++frameNumber) {
				
				(static_cast<AudioUnitSampleType *>(ioData->mBuffers[0].mData))[frameNumber] = soundStructDelegate[inBusNumber].audioDataLeftBuffers[soundStructDelegate[inBusNumber].audioDataCurrentBuffer][soundStructDelegate[inBusNumber].readSampleNumber];
				if (soundStructDelegate[inBusNumber].isStereo) 
					(static_cast<AudioUnitSampleType *>(ioData->mBuffers[1].mData))[frameNumber] = soundStructDelegate[inBusNumber].audioDataRightBuffers[soundStructDelegate[inBusNumber].audioDataCurrentBuffer][soundStructDelegate[inBusNumber].readSampleNumber];
				
				++soundStructDelegate[inBusNumber].readSampleNumber;
			}
		}
	}
	else {
	
		// Use fixedFramesForThisCallback instead of inNumberFrames so we don't collect 4096 samples in the middle of this for loop
		for (UInt32 frameNumber = 0; frameNumber < soundStructDelegate[inBusNumber].fixedFramesForThisCallback; ++frameNumber) {
			
			(static_cast<AudioUnitSampleType *>(ioData->mBuffers[0].mData))[frameNumber] = soundStructDelegate[inBusNumber].audioDataLeftBuffers[soundStructDelegate[inBusNumber].audioDataCurrentBuffer][soundStructDelegate[inBusNumber].readSampleNumber];
			if (soundStructDelegate[inBusNumber].isStereo) 
				(static_cast<AudioUnitSampleType *>(ioData->mBuffers[1].mData))[frameNumber] = soundStructDelegate[inBusNumber].audioDataRightBuffers[soundStructDelegate[inBusNumber].audioDataCurrentBuffer][soundStructDelegate[inBusNumber].readSampleNumber];
			
			++soundStructDelegate[inBusNumber].readSampleNumber;
		}
	}
	
	// If we've reached the last sample in this buffer...
	if (soundStructDelegate[inBusNumber].readSampleNumber == soundStructDelegate[inBusNumber].framesPerBuffer) {
		
		// Set the reference to the current buffer to fill to the next buffer in sequence (1 to 2, 2 to 0, 0 to 1)
        if (++soundStructDelegate[inBusNumber].audioDataCurrentBuffer == soundStructDelegate[inBusNumber].numBuffers)
			soundStructDelegate[inBusNumber].audioDataCurrentBuffer = 0;
		
		// indirectly request that the ring buffer thread fetch another buffer with ExtAudioFileRead
		OSAtomicAdd32(1,&soundStructDelegate[inBusNumber].requestNextBuffer);
        
        // Start reading from the very beginning of the buffer
		soundStructDelegate[inBusNumber].readSampleNumber = 0;
	}
    
    return noErr;
}

#pragma mark -
#pragma mark Initialize

// Get the app ready for playback.
NLRemoteIOAudioPlayer::NLRemoteIOAudioPlayer() {
    
    soundStructUnit.numBuffers = 3;
    // .numBuffers must be set before calling allocRioAudioPlayerBuffers - has to be at least 3.
    
	framesToReadFromFile = 16384;
    // framesToReadFromFile must be set before calling configureAndInitializeRioAudioPlayer - if too high, will cause problems with multithreading and use of the not thread safe ExtAudioFileServices API during a series of seek operations or rapid requests to stop and start audio playback. If too low, will tax CPU more than necessary.
    
	//
    //      DON'T FORGET: When sleeping, the inNumberFrames variable in the render callback changes from 1024 to 4096. Therefore, the individual buffers
    //      should be set to a multiple of 4096
    //
	
    playing = NO;
	interruptedDuringPlayback = NO;
    scrollingDuringPlayback = NO;
    
    cancelScrollQueue = 1;
    // rule of thumb; NEVER set cancelScrollQueue with a standard assignment statement whenever there's a thread/block observing its value
    
    audioFileReference = nil;
    audioFileObject = nil;
    
    ringBufferList = 0;
    
    setupAudioSession();
	configureAndInitializeRioAudioPlayer();
	allocRioAudioPlayerBuffers();
	
	// Request the desired hardware sample rate. (44100.0 for all current iOS devices)
	Float64 unitSampleRate;
	UInt32 sampleRateSize = sizeof(Float64);
	AudioSessionGetProperty (kAudioSessionProperty_CurrentHardwareSampleRate,
							 &sampleRateSize, 
							 &unitSampleRate);
	
	framesBuffered.value = 0;
	framesBuffered.timescale = unitSampleRate;
	framesBuffered.flags |= kCMTimeFlags_Valid;
    
    ringBufferQueue = dispatch_queue_create("com.NLRemoteIOAudioPlayer.RingBufferBlockQueue", NULL);
    scrollQueue = dispatch_queue_create("com.NLRemoteIOAudioPlayer.ScrollBlockQueue", NULL);	
}

#pragma mark -
#pragma mark Audio set up

void NLRemoteIOAudioPlayerInterruptionListener(void *inClientData, UInt32 inInterruptionState)
{    
    // This callback, being outside the implementation block, needs a reference to the MixerHostAudio
    //   object, which it receives in the inUserData parameter. You provide this reference when
    //   registering this callback (see the call to AudioSessionAddPropertyListener).
    NLRemoteIOAudioPlayer *audioObject = static_cast<NLRemoteIOAudioPlayer *>(inClientData);
    
    // if application sound is not playing, there's nothing to do, so return.
    if (NO == audioObject->isPlaying()) {
        //printf("Audio route change while application audio is stopped. \n");
        return;
        
    } else {
        
        if (inInterruptionState == kAudioSessionBeginInterruption) {
            
			//printf("Audio output device was removed; stopping audio playback. \n");
            
            audioObject->stopRioAudioPlayer();
            
            dispatch_async(dispatch_get_main_queue(), ^{
                if([audioObject->_delegate respondsToSelector:@selector(updateViewForRemoteIOAudioPlayerState)]) {
                    [audioObject->_delegate updateViewForRemoteIOAudioPlayerState];
                }
            });
        }
		else {
            
            //printf("A route change occurred that does not require stopping application audio. \n");
        }
    }
}

void NLRemoteIOAudioPlayer::setupAudioSession() {
    
    // Register the audio route change listener callback function with the audio session.

    OSStatus result = AudioSessionInitialize(NULL, NULL, NLRemoteIOAudioPlayerInterruptionListener, this);
    
    // Assign the Playback category to the audio session.
    UInt32 sessionCategory = kAudioSessionCategory_MediaPlayback;
    
    AudioSessionSetProperty (
                             kAudioSessionProperty_AudioCategory,
                             sizeof (sessionCategory),
                             &sessionCategory
                             );
    
    // Activate the audio session
    result = AudioSessionSetActive (true);
}


void NLRemoteIOAudioPlayer::setupStreamFormatWithChannels(short unsigned int numChannels) {
    
    // Specify the stream format for output side of the I/O unit's 
	//	input bus (bus 1). For a description of these fields, see 
	//	AudioStreamBasicDescription in Core Audio Data Types Reference.
	//
	// Instead of explicitly setting the fields in the ASBD as is done 
	//	here, you can use the SetAUCanonical method from the Core Audio 
	//	"Examples" folder. Refer to:
	//		/Developer/Extras/CoreAudio/PublicUtility/CAStreamBasicDescription.h
    
    // The AudioUnitSampleType data type is the recommended type for sample data in audio
    //    units. This obtains the byte size of the type for use in filling in the ASBD.
    size_t bytesPerSample = sizeof (AudioUnitSampleType);
    
    // Fill the application audio format struct's fields to define a linear PCM, 
    //        stereo, noninterleaved stream at the hardware sample rate.
    streamFormat.mFormatID = kAudioFormatLinearPCM;
    streamFormat.mFormatFlags = kAudioFormatFlagsAudioUnitCanonical;
    streamFormat.mChannelsPerFrame = numChannels;
    streamFormat.mFramesPerPacket = 1;
    streamFormat.mBitsPerChannel = 8 * bytesPerSample;
    streamFormat.mBytesPerPacket = streamFormat.mBytesPerFrame = bytesPerSample;
	
    // Sample rate must be the same as the output, otherwise playback is too fast or slow, which affects pitch
    streamFormat.mSampleRate        = 	framesBuffered.timescale;
    
    //printf("The stream format for the mixer input bus: \n");
    //printASBD(streamFormat);
}


#pragma mark -
#pragma mark Read audio files into memory

void NLRemoteIOAudioPlayer::setCurrentBuffers(signed char requestedBuffer) {
    
    if (requestedBuffer < 0) {
        requestedBuffer += soundStructUnit.numBuffers;
    }
    ringBufferList->mBuffers[0].mData = soundStructUnit.audioDataLeftBuffers[requestedBuffer];
    if (soundStructUnit.isStereo) {
        ringBufferList->mBuffers[1].mData = soundStructUnit.audioDataRightBuffers[requestedBuffer];
    }
};

UInt32 NLRemoteIOAudioPlayer::readFramesFromFile(UInt32 framesToRead) {
    
    //printf("framesBuffered.value is %lld \n",framesBuffered.value);
    
    OSStatus result = ExtAudioFileRead (audioFileObject, &framesToRead, ringBufferList);
    if (noErr == result) {
        incrementFramesElapsed(framesToRead);
    }
    else {
        printErrorMessageWithStatus("Could not read file within ^readFramesFromFile", result); 
        
        printf("The number of frames that were read from the file is %lu \n",framesToRead);
        printf("framesBuffered.value is %lld \n",framesBuffered.value);
        printf("fileDuration.value is %lld \n",fileDuration.value);
    }
    return framesToRead;
}

void NLRemoteIOAudioPlayer::readLastSegmentOfFramesFromFile() {
    
    //
    // for the very last segment of audio in the file, only read in the remaining number of frames
    //
    
    // start from a clean set of buffers
    
    memset(ringBufferList->mBuffers[0].mData,0,(framesToReadFromFile * 4));
    if (soundStructUnit.isStereo) {
        memset(ringBufferList->mBuffers[1].mData,0,(framesToReadFromFile * 4));
    }
    
    //
    // !!!: hack to get around an issue where ExtAudioFileRead misrepresents the number of frames read
    //
    // ExtAudioFileRead SHOULDN'T attempt to return a negative result for ioNumberFrames (should 
    // report an error), but it does. As this doesn't appear to have any correlation with the frames 
    // we offset from a packet while seeking, I believe this may be an honest to goodness bug in the API
    //
    
    if (readFramesFromFile(framesRemainingInFile) > framesRemainingInFile) {
        framesRemainingInFile = 0;
    }
    
    // printf("The number of frames that were read from the file is %lu \n",framesRead);
}

// this will be for the first pass...
void NLRemoteIOAudioPlayer::readAudioFileIntoMemoryWithURL(CFURLRef sourceURL) {
    
	//printf("readAudioFilesIntoMemory - file %i \n", 0);
	
	if (audioFileObject != nil) {
		ExtAudioFileDispose(audioFileObject);
		audioFileObject = nil;
	}
		
	// to avoid managing more pointer junk, we're keeping the AudioFileServices variables on the stack and within their own local scope
	{
		// get the file's bitrate for seek/tell operations
		AudioFileID outAFID;
	
		OSStatus result = AudioFileOpenURL(sourceURL, kAudioFileReadPermission, 0, &outAFID);
		if (noErr != result) 
		{
			printErrorMessageWithStatus("Could not create AFS reference for given file",result); 
			return;
		}
	
		// we can find the file's sample rate by calling kAudioFilePropertyDataFormat via AudioFileGetProperty, and retrieve its .mSampleRate property.
		AudioStreamBasicDescription fileStreamDescription = {0};
		UInt32 fileStreamDescriptionPropertySize = sizeof(fileStreamDescription);
		result = AudioFileGetProperty(outAFID, kAudioFilePropertyDataFormat, &fileStreamDescriptionPropertySize, &fileStreamDescription);
		if (noErr != result) {printErrorMessageWithStatus("Could not retrieve property information from this file",result); return;}
				
		fileDuration.timescale = fileStreamDescription.mSampleRate;
		
		result = AudioFileClose(outAFID);
		if (noErr != result) 
		{
			printErrorMessageWithStatus("Could not close the AFS reference for given file",result); 
			return;
		}
	}
	
	// Open an audio file and associate it with the extended audio file object.
	OSStatus result = ExtAudioFileOpenURL (sourceURL, &audioFileObject);
	
	if (noErr != result || NULL == audioFileObject) {printErrorMessageWithStatus("ExtAudioFileOpenURL",result); return;}
	
	// Get the audio file's length in frames.
	SInt64 totalFramesInFile = 0;
	UInt32 frameLengthPropertySize = sizeof (totalFramesInFile);
	
	result =    ExtAudioFileGetProperty (
										 audioFileObject,
										 kExtAudioFileProperty_FileLengthFrames,
										 &frameLengthPropertySize,
										 &totalFramesInFile
										 );
		
	if (noErr != result) {printErrorMessageWithStatus("ExtAudioFileGetProperty (audio file length in frames)",result); return;}
	
	// Get the audio file's number of channels.
	AudioStreamBasicDescription fileAudioFormat = {0};
	UInt32 formatPropertySize = sizeof (fileAudioFormat);
	
	result =    ExtAudioFileGetProperty (
										 audioFileObject,
										 kExtAudioFileProperty_FileDataFormat,
										 &formatPropertySize,
										 &fileAudioFormat
										 );
	
	if (noErr != result) {printErrorMessageWithStatus("ExtAudioFileGetProperty (file audio format)",result); return;}
	
	UInt32 channelCount = fileAudioFormat.mChannelsPerFrame;
		
	AudioStreamBasicDescription importFormat = {0};
	if (2 == channelCount) {
		setupStreamFormatWithChannels(2);
		
		soundStructUnit.isStereo = YES;
		importFormat = streamFormat;
		
	} else if (1 == channelCount) {
		// Sound is mono
		setupStreamFormatWithChannels(1);
		
		soundStructUnit.isStereo = NO;
		importFormat = streamFormat;
		
	} else {
		
		// Today's iOS devices can't take advantage of speakers with more than two channels.
		//		We expect audio data to behave the same way.
		printf ("*** WARNING: File format not supported - wrong number of channels \n");
		ExtAudioFileDispose (audioFileObject);
		return;
	}
	
    //
	// Assign the appropriate rio input bus stream data format to the extended audio 
	//        file object. This is the format used for the audio data placed into the audio 
	//        buffer in the SoundStruct data structure, which is in turn used in the 
	//        inputRenderCallback callback function.
	//
    
    result =    ExtAudioFileSetProperty (
                                        audioFileObject,
                                        kExtAudioFileProperty_ClientDataFormat,
                                        sizeof (importFormat),
                                        &importFormat
                                        );
	
	if (noErr != result) { printErrorMessageWithStatus("ExtAudioFileSetProperty (client data format)",result); return; }
	
	//
	// "After you've opened the file and set the client format, call ExtAudioFileTell(). If the  
	// position is negative, we haven't fixed the bug and ExtAudioFileTell()'s results are off by the returned value."
	// 
	// - Doug Wyatt of Apple's Core Audio Team. http://web.archiveorange.com/archive/v/q7bubDpEWAixl3z7oPMu
	// 
	// This bug also affects the output of ExtAudioFileGetProperty wrt retrieving frames and seek position.
	// 
	
	extAFSOffset = 0;
	
	result = ExtAudioFileTell(
							  audioFileObject,
							  &extAFSOffset
							  );
	
    //printf("extAFSOffset is %i \n",extAFSOffset);
    
	// compensate to get the correct number of frames in this file
	totalFramesInFile = totalFramesInFile - extAFSOffset;
	
	if (totalFramesInFile <= framesToReadFromFile) {
		framesToReadFromFile = static_cast<UInt32>(totalFramesInFile);
	}
	
	fileDuration.value = totalFramesInFile * (framesBuffered.timescale/fileDuration.timescale);	// frames in the entire file
	soundStructUnit.framesPerBuffer = framesToReadFromFile;                                             // frames per iteration of the callback

	fileDuration.flags |= kCMTimeFlags_Valid;
	
	if (noErr != result) {printErrorMessageWithStatus("ExtAudioFileSetProperty (client data format)",result); return;}
		
	// Set the sample index to zero, so that playback starts at the 
	//    beginning of the sound.
	soundStructUnit.readSampleNumber = 0;
	
	// Keep a reference to the URL of the new file
	audioFileReference = sourceURL;
}

void NLRemoteIOAudioPlayer::configureAndInitializeRioAudioPlayer() {
	
	// Describe audio component
	AudioComponentDescription iOUnitDescription;
	iOUnitDescription.componentType = kAudioUnitType_Output;
	iOUnitDescription.componentSubType = kAudioUnitSubType_RemoteIO;
	iOUnitDescription.componentFlags = 0;
	iOUnitDescription.componentFlagsMask = 0;
	iOUnitDescription.componentManufacturer = kAudioUnitManufacturer_Apple;
	
	// Get component
	AudioComponent inputComponent = AudioComponentFindNext(NULL, &iOUnitDescription);
	
	// Get audio units
	OSStatus result = AudioComponentInstanceNew(inputComponent, &RioAudioPlayer);
	if (noErr != result) {printErrorMessageWithStatus("Couldn't retrieve an audio unit component of type RemoteIO", result); return;}
	
	// To indicate to kAudioOutputUnitProperty_EnableIO that we want to play back audio through RemoteIO (see documentation)
	UInt32 enableOutput = 1;
	
	// Enable IO for playback
	result = AudioUnitSetProperty(RioAudioPlayer, 
								  kAudioOutputUnitProperty_EnableIO, 
								  kAudioUnitScope_Output, 
								  0,
								  &enableOutput, 
								  sizeof(enableOutput));
	if (noErr != result) {printErrorMessageWithStatus("Couldn't enable output for RemoteIO AudioPlayer",result); return;}
		
	// Set up the playback  callback
	AURenderCallbackStruct inputCallbackStruct;
	inputCallbackStruct.inputProc = inputRenderCallback; // callback function
	inputCallbackStruct.inputProcRefCon = &soundStructUnit;
	
	result = AudioUnitSetProperty(RioAudioPlayer, 
								  kAudioUnitProperty_SetRenderCallback, 
								  kAudioUnitScope_Global, 
								  0,
								  &inputCallbackStruct, 
								  sizeof(inputCallbackStruct));
	if (noErr != result) {printErrorMessageWithStatus("Could not set up render callback for RemoteIO AudioPlayer",result); return;}
	
	result = AudioUnitInitialize(RioAudioPlayer);
	if (noErr != result) {printErrorMessageWithStatus("Could not initialize RemoteIO AudioPlayer",result); return;}
}

void NLRemoteIOAudioPlayer::allocRioAudioPlayerBuffers() {

	// Allocate memory in the soundStructArray instance variable to hold the left channel, 
	//    or mono, audio data
	
	soundStructUnit.audioDataLeftBuffers = static_cast<AudioUnitSampleType**>(malloc(soundStructUnit.numBuffers * sizeof(AudioUnitSampleType *)));
	
	for (int i = 0; i < soundStructUnit.numBuffers; ++i) {
		soundStructUnit.audioDataLeftBuffers[i] =
		static_cast<AudioUnitSampleType *>(calloc (framesToReadFromFile, sizeof (AudioUnitSampleType)));
	}
	
	// Sound can be stereo, so allocate memory in the soundStructArray instance variable to  
	//    hold the right channel audio data
	
	soundStructUnit.audioDataRightBuffers = static_cast<AudioUnitSampleType**>(malloc(soundStructUnit.numBuffers * sizeof(AudioUnitSampleType *)));
	
	for (int i = 0; i < soundStructUnit.numBuffers; ++i) {
		soundStructUnit.audioDataRightBuffers[i] =
		static_cast<AudioUnitSampleType *>(calloc (framesToReadFromFile, sizeof (AudioUnitSampleType)));
	}	
}

void NLRemoteIOAudioPlayer::startRioAudioPlayer() {
	
	// This little if statement is not a bad sanity check to have - goes to "else" when we're at the EOF and there are no buffers to load
	if (estimatedIterationsBeforeEOF != -soundStructUnit.numBuffers) {
		
        if (!scrollingDuringPlayback)
            cancelScrollQueue = 0;
        
        void (^cycleRingBufferAsBlock)(void) = ^(void){
            cycleRingBuffer();
            };
        
        //
        // Jeff Moore - "All you really need is a timer thread that watches the wall clock and queues up the buffers for the sound engine 
        // to play in it's next cycle." ( http://lists.apple.com/archives/Coreaudio-api/2005/Sep/msg00231.html )
        //
        // Which is exactly what this libdispatch thread does.
        //
        
        ringBufferCycle = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, ringBufferQueue);
        dispatch_source_set_timer(ringBufferCycle, dispatch_time(DISPATCH_TIME_NOW, 0), 0.15 * NSEC_PER_SEC, 0.1 * NSEC_PER_SEC);
        dispatch_source_set_event_handler(ringBufferCycle,cycleRingBufferAsBlock);
        dispatch_resume(ringBufferCycle);
        
        playRingBufferAudio();
		[UIApplication sharedApplication].idleTimerDisabled = YES;
	}
	else {
		// we're at the end of the file, so inform the delegate
        dispatch_async(dispatch_get_main_queue(), ^{
            if([_delegate respondsToSelector:@selector(rioPlaybackDidEnd)]) {
                [_delegate rioPlaybackDidEnd];
            }
        });
	}
}

void NLRemoteIOAudioPlayer::startRioAudioPlayerWithInputURL(CFURLRef path) {
	
    if (playing == YES) {
        stopRioAudioPlayer();
    }
    
    free(ringBufferList);
    
    readAudioFileIntoMemoryWithURL(path);
    
    // Apply format described by readAudioFileIntoMemoryWithURL
    AudioUnitUninitialize(RioAudioPlayer);
    
    OSStatus result = AudioUnitSetProperty(RioAudioPlayer, 
                                           kAudioUnitProperty_StreamFormat, 
                                           kAudioUnitScope_Input, 
                                           0, 
                                           &streamFormat, 
                                           sizeof(streamFormat));
    
    if (noErr != result) {printErrorMessageWithStatus("Couldn't specify PCM stream format for RemoteIO AudioPlayer", result); return;}
    
    AudioUnitInitialize(RioAudioPlayer);
    
    allocRingBufferAtPosition(0);
    initRingBuffer();
	
    // TODO: from here on, we could field a "cancel selector" request to skip a few steps
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if([_delegate respondsToSelector:@selector(updateViewForRemoteIOAudioPlayerDuration)]) {
            [_delegate updateViewForRemoteIOAudioPlayerDuration];
        }
        
        if([_delegate respondsToSelector:@selector(updateViewForRemoteIOAudioPlayerAlbumInfo)]) {
            [_delegate updateViewForRemoteIOAudioPlayerAlbumInfo];
        }
    });
    
    startRioAudioPlayer();
}

void NLRemoteIOAudioPlayer::stopRioAudioPlayer() {
    
	AudioOutputUnitStop(RioAudioPlayer);

    dispatch_source_cancel(ringBufferCycle);
    dispatch_release(ringBufferCycle);
		
	playing = NO;
			
	[UIApplication sharedApplication].idleTimerDisabled = NO;
}


#pragma mark -
#pragma mark Utility methods

// You can use this method during development and debugging to look at the
//    fields of an AudioStreamBasicDescription struct.
void NLRemoteIOAudioPlayer::printASBD(AudioStreamBasicDescription asbd) {
    
    char formatIDString[5];
    UInt32 formatID = CFSwapInt32HostToBig (asbd.mFormatID);
    memmove (&formatID, formatIDString, 4);
    formatIDString[4] = '\0';
    
    printf ("  Sample Rate:         %10.0f \n",  asbd.mSampleRate);
    printf ("  Format ID:           %10s \n",    formatIDString);
    printf ("  Format Flags:        %10X \n",    static_cast<unsigned int>(asbd.mFormatFlags));
    printf ("  Bytes per Packet:    %10d \n",    static_cast<unsigned int>(asbd.mBytesPerPacket));
    printf ("  Frames per Packet:   %10d \n",    static_cast<unsigned int>(asbd.mFramesPerPacket));
    printf ("  Bytes per Frame:     %10d \n",    static_cast<unsigned int>(asbd.mBytesPerFrame));
    printf ("  Channels per Frame:  %10d \n",    static_cast<unsigned int>(asbd.mChannelsPerFrame));
    printf ("  Bits per Channel:    %10d \n",    static_cast<unsigned int>(asbd.mBitsPerChannel));
}


void NLRemoteIOAudioPlayer::printErrorMessageWithStatus(const char* errorString, OSStatus result) {
    
	printf("ERROR: %s with status %i \n",errorString,static_cast<int>(result));
}


#pragma mark -
#pragma mark Deallocate

NLRemoteIOAudioPlayer::~NLRemoteIOAudioPlayer() {
	
	stopRioAudioPlayer();
    
    // stopRioAudioPlayer() cleans up the ringBufferCycle, but not the ringBufferQueue, so we do that here...
    
    dispatch_release(ringBufferQueue);
    dispatch_release(scrollQueue);

	// keep the reference for as long as we need to play back audio
	if (audioFileObject != nil) {
		
        // we close the reference to the file, and leave additional file cleanup tasks for the delegate
        
		ExtAudioFileDispose(audioFileObject);
		audioFileObject = nil;
	}
    
    if (audioFileReference != nil) {
        
        CFRelease(audioFileReference);
        audioFileReference = nil;
    }
		
	if (soundStructUnit.audioDataLeftBuffers != NULL) {
        
		for (int i = 0; i < soundStructUnit.numBuffers; ++i) {
			if (soundStructUnit.audioDataLeftBuffers[i] != NULL) {
				free (soundStructUnit.audioDataLeftBuffers[i]);
			}
		}
		
		free (soundStructUnit.audioDataLeftBuffers);
		
		for (int i = 0; i < soundStructUnit.numBuffers; ++i) {
            if (soundStructUnit.audioDataRightBuffers[i] != NULL) {
                free (soundStructUnit.audioDataRightBuffers[i]);
            }
        }
        
        free (soundStructUnit.audioDataRightBuffers);
	}
	
	if (ringBufferList != NULL) {
        
		free(ringBufferList);
        ringBufferList = 0;
    }
}


#pragma mark -
#pragma mark Ring Buffer Processing

void NLRemoteIOAudioPlayer::allocRingBufferAtPosition(SInt64 seekPosition) {
	
	soundStructUnit.requestNextBuffer = 0;
	
	AudioBuffer emptyBuffer = {0};

	// init and malloc bufferList with empty values (depending on how many channels this file has)
	if (soundStructUnit.isStereo) {
		ringBufferList = static_cast<AudioBufferList *>(malloc (28));//sizeof (AudioBufferList) + sizeof (AudioBuffer));	// two buffers malloced
		ringBufferList->mNumberBuffers = 2;
		ringBufferList->mBuffers[1] = emptyBuffer;
	}
	else {
		ringBufferList = static_cast<AudioBufferList *>(malloc (16));//sizeof (AudioBufferList)	// one buffer malloced
		ringBufferList->mNumberBuffers = 1;
		ringBufferList->mBuffers[0] = emptyBuffer;
	}
	
	framesRemainingInFile = fileDuration.value - seekPosition;
	
    // as long as framesRemaining DOES NOT exceed the duration of this file...
	if (framesRemainingInFile <= fileDuration.value)	{
        
        // estimate the number of loops we'll have to make before we reach the dreaded EOF
        // (this isn't certain, because ExtAudioFileRead will sometimes retrieve fewer samples than we requested)
		estimatedIterationsBeforeEOF = floor(framesRemainingInFile / framesToReadFromFile) - soundStructUnit.numBuffers;
    }
	else {
        
        // seekPosition has fallen out of fileDuration.value's bounds, so assume we have no more frames to read in
        framesRemainingInFile = 0;
        
		estimatedIterationsBeforeEOF = -soundStructUnit.numBuffers;
	}

	setFramesBufferedAtSamplePosition(seekPosition);
}


void NLRemoteIOAudioPlayer::initRingBuffer() {
	
	// only init as many buffers as we need, if we're reading from a position close to the end of the file or a very short clip.
		
	short unsigned int buffersToCreate;
	
	if (estimatedIterationsBeforeEOF < 0) {
		
        //
		// if numBuffers == 3, and we only need to fill one or two, iterationsBeforeEOF should be a negative integer
		// that is greater than (-soundStructUnit.numBuffers + 1)
		//
        // if we continue to assume that numBuffers == 3...
        //
		// if estimatedIterationsBeforeEOF is 0, we enter the "else" condition, and we fill (numBuffers) of the buffers (3 buffers),
		// if estimatedIterationsBeforeEOF is -1, we enter this "if" condition, and we fill (numBuffers-1) buffers (2 buffers),
		// if estimatedIterationsBeforeEOF is -2, this "if" condition fills only 1 buffer, which is what we want;
		//		we go through the callback ONCE then stop the RemoteIO AudioPlayer
		//
        
		buffersToCreate = soundStructUnit.numBuffers + estimatedIterationsBeforeEOF;
    }
	else {
		buffersToCreate = soundStructUnit.numBuffers;
	}

	
	ringBufferList->mBuffers[0].mNumberChannels		 = 1;
	ringBufferList->mBuffers[0].mDataByteSize		 = framesToReadFromFile * 4;		// sizeof (AudioUnitSampleType) == 4. 
	
	if (soundStructUnit.isStereo) {
		ringBufferList->mBuffers[1].mNumberChannels  = 1;
		ringBufferList->mBuffers[1].mDataByteSize    = framesToReadFromFile * 4;
	}
			
	for (int i = 0; i < buffersToCreate; ++i) {
		ringBufferList->mBuffers[0].mData            = soundStructUnit.audioDataLeftBuffers[i];
		if (soundStructUnit.isStereo) {
			ringBufferList->mBuffers[1].mData        = soundStructUnit.audioDataRightBuffers[i];
		}
		
        if (!((estimatedIterationsBeforeEOF <= 0) && (i == buffersToCreate))) {
            // locking down these numbers because on output, ExtAudioFileRead may change it to a smaller number due to a 
            //      possible "optimization"; http://osdir.com/ml/coreaudio-api/2010-09/msg00050.html
            
            readFramesFromFile(framesToReadFromFile);
        }
        else {            
            readLastSegmentOfFramesFromFile();
        }
	}
	
	// start reading from the very first buffer
	soundStructUnit.audioDataCurrentBuffer = 0;
}

void NLRemoteIOAudioPlayer::cycleRingBuffer() {
    
    // if we have a buffer available, pre-render into that audio ringbuffer
    if (soundStructUnit.requestNextBuffer != 0) {
        
        // make local copies of the audio buffer being read and the number of buffers requested _just before_ we enter the do-while loop
        unsigned char currentBuffer = soundStructUnit.audioDataCurrentBuffer;
        int32_t queuedBufferRequests = soundStructUnit.requestNextBuffer;
        
        // fulfill queued requests to fill the next buffer(s)
        do {
            --estimatedIterationsBeforeEOF;
            
            if (framesRemainingInFile != 0) {
                
                // Determine the last set of buffers that the callback read data from, and have our AudioBufferList point to that set
                // 
                setCurrentBuffers(currentBuffer - queuedBufferRequests);
                
                // If we haven't reached the sample just before the end of the file, read a full sample
                if (framesRemainingInFile >= framesToReadFromFile) {
                    
                    readFramesFromFile(framesToReadFromFile);
                    
                }
                // framesRemainingInFile < framesToReadFromFile - handle exception here
                else {
                    readLastSegmentOfFramesFromFile();					
                }
            }
            else if (estimatedIterationsBeforeEOF <= -soundStructUnit.numBuffers) {
                
                // assume our Audio Unit has finished playing back the last sample of audio
                
                // cancel all queued requests to scrub the audio
                OSAtomicOr32(1, &cancelScrollQueue);
                
                // stop the audio unit, as it has finished playing the end of the sound file
                stopRioAudioPlayer();
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    if([_delegate respondsToSelector:@selector(rioPlaybackDidEnd)]) {
                        [_delegate rioPlaybackDidEnd];
                    }
                });
                
                // for safety, reset the number of requests to fetch the next buffer to 0 and return
                soundStructUnit.requestNextBuffer = queuedBufferRequests = 0;
                
                return;
            }
            else {
                //
                // we've read the last few frames of the audio file, but our Audio Unit hasn't finished playing back the last sample of audio
                //
                // here, we try to reduce the risk of playing back a stored buffer twice by zeroing out allocated values from buffers we've 
                // already played back... but the Audio Unit callback can sometimes outrun this thread. Would be nice if we had a better 
                // strategy to stop audio in its tracks without incurring a significant performance penalty.
                //
                // (believe me; I've tried)
                //
                
                signed char requestedBuffer = currentBuffer - queuedBufferRequests;
                
                if (requestedBuffer < 0) {
                    requestedBuffer += soundStructUnit.numBuffers;
                }
                
                memset(soundStructUnit.audioDataLeftBuffers[requestedBuffer],0,(framesToReadFromFile * 4));
                if (soundStructUnit.isStereo) {
                    memset(soundStructUnit.audioDataRightBuffers[requestedBuffer],0,(framesToReadFromFile * 4));
                }
            }
            
            OSAtomicAdd32(-1,&soundStructUnit.requestNextBuffer);
        }
        while (--queuedBufferRequests > 0);
    }
}

// contains a subset of readAudioFileIntoMemory made for iteration - necessary for smarter memory management and i/o on memory constrained devices
void NLRemoteIOAudioPlayer::playRingBufferAudio() {
		
	// start playing the AU (only AFTER we preallocate buffers, otherwise we risk a race condition)
	AudioOutputUnitStart(RioAudioPlayer);
	
	playing = YES;
	
    dispatch_async(dispatch_get_main_queue(), ^{
        if([_delegate respondsToSelector:@selector(updateViewForRemoteIOAudioPlayerState)]) {
            [_delegate updateViewForRemoteIOAudioPlayerState];
        }
    });
}

#pragma mark -
#pragma mark Seek methods

// !!!: this function, when called by a UIKit slider, is handling input asynchronously. Expect at least three asynchronous calls for the smallest movements
void NLRemoteIOAudioPlayer::seekToPosition(float seekTime) {
	
    dispatch_sync(scrollQueue, ^{    
        
        if (!cancelScrollQueue) {
            
            // TODO: make more adjustments necessary to have this seeking solution (and EOF measurement) work for sample rates besides 44100
            
            // treat sliding like an interrupt operation so we can stop/resume playback if we're already playing audio
            if (playing) {
                stopRioAudioPlayer();
                scrollingDuringPlayback = YES;
            }
            
            //printf("nextPosition will be %f \n", seekTime * fileDuration.timescale);
            
            AudioFramePacketTranslation fileStreamFPTranslation;
            
            
            AudioFileID outAFID;
            AudioFileOpenURL(audioFileReference, kAudioFileReadPermission, 0, &outAFID);
            
            // we can find the file's sample rate by calling kAudioFilePropertyDataFormat via AudioFileGetProperty, and retrieve its .mSampleRate property
            
            UInt32 fileStreamFPTranslationSize = 20; //sizeof(AudioFramePacketTranslation);
            fileStreamFPTranslation.mFrame = seekTime * fileDuration.timescale; //floor(seekTime * (totalFrameCount / fileSampleRateRatio));
            AudioFileGetProperty(outAFID, kAudioFilePropertyFrameToPacket, &fileStreamFPTranslationSize, &fileStreamFPTranslation);
            AudioFileGetProperty(outAFID, kAudioFilePropertyPacketToFrame, &fileStreamFPTranslationSize, &fileStreamFPTranslation);
            AudioFileClose(outAFID);
            
            // seek, adjusting so that we don't read in the middle of a packet (BAD!)
            OSStatus result = ExtAudioFileSeek(audioFileObject, fileStreamFPTranslation.mFrame);
            if (noErr != result) {printErrorMessageWithStatus("Could not seek file",result); return;}
                        
            
            // value/timescale = seconds
            // value = seconds * timescale
            
            free(ringBufferList);
            
            allocRingBufferAtPosition(floor(seekTime * framesBuffered.timescale));

            initRingBuffer();
            
            // update the UI (absolutely necessary if playback was paused)
            dispatch_async(dispatch_get_main_queue(), ^{
                if([_delegate respondsToSelector:@selector(updateViewForRemoteIOAudioPlayerState)]) {
                    [_delegate updateViewForRemoteIOAudioPlayerState];
                }
            });
                
            if (cancelScrollQueue == 0) {
                if (scrollingDuringPlayback) {
                    startRioAudioPlayer();
                }
            }
            
            scrollingDuringPlayback = NO;
        }
    });
}

#pragma mark -
#pragma mark Playback Position Tracking methods

float NLRemoteIOAudioPlayer::getFileDurationInSeconds() {
	return fileDuration.value/framesBuffered.timescale;
}

SInt64 NLRemoteIOAudioPlayer::convertSecondsToRemoteIOSamples(float seconds) {
	
	// Translates seconds -> frames in a given file for seeking forward or back in fixed durations based on time.
	// Equation should be based on sample rate... 44100 samples for every second. Consider a single frame to be a sample in this case.
	// So 1 frame == (1/44100) seconds of audio data.
	
	return static_cast<SInt64>(floor(seconds * framesBuffered.timescale));
	
	//printf("Converting %f seconds to the corresponding representation in frames \n", seconds);
}

void NLRemoteIOAudioPlayer::setFramesBufferedAtSamplePosition(SInt64 position) {
	
	framesBuffered.value = position;
    
    // if we used seekTime as an input, then framesBuffered.value = floor(seekTime * unitSampleRate);
	
	//printf("Current sample position is reported to be %i \n", framesBuffered.value);
	
}

void NLRemoteIOAudioPlayer::incrementFramesElapsed(UInt32 numSamples)	{
	
	framesBuffered.value += numSamples;
	framesRemainingInFile -= numSamples;
	//printf("Current playback time in frames is reported to be %i \n", framesBuffered.value);
	
}