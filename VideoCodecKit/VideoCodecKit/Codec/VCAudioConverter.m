//
//  VCAudioConverter.m
//  VideoCodecKit
//
//  Created by CmST0us on 2019/2/6.
//  Copyright © 2019 eric3u. All rights reserved.
//

#import "VCAudioConverter.h"

@interface VCAudioConverter ()
@property (nonatomic, assign) AudioConverterRef converter;

@property (nonatomic, assign) AudioBufferList currentBufferList;
@property (nonatomic, assign) CMBlockBufferRef currentAudioBlockBuffer;
@property (nonatomic, assign) AudioStreamPacketDescription currentAudioStreamPacketDescription;

@property (nonatomic, readonly) NSUInteger maxBufferSize;
@property (nonatomic, readonly) NSUInteger ioOutputDataPacketSize;
@end

@implementation VCAudioConverter

static OSStatus audioConverterInputDataProc(AudioConverterRef inAudioConverter,
                                            UInt32 *          ioNumberDataPackets,
                                            AudioBufferList * ioData,
                                            AudioStreamPacketDescription * __nullable * __nullable outDataPacketDescription,
                                            void * __nullable inUserData) {
    VCAudioConverter *converter = (__bridge VCAudioConverter *)inUserData;
    return [converter converterInputDataProcWithConverter:inAudioConverter ioNumberDataPackets:ioNumberDataPackets ioData:ioData outDataPacketDescription:outDataPacketDescription];
}

- (OSStatus)converterInputDataProcWithConverter:(AudioConverterRef)inAudioConverter
                            ioNumberDataPackets:(UInt32 *)ioNumberDataPackets
                                         ioData:(AudioBufferList *)ioData
                       outDataPacketDescription:(AudioStreamPacketDescription **)outDataPacketDescription {
    memcpy(ioData, &_currentBufferList, sizeof(_currentBufferList));
    // !!! if decode aac, must set outDataPacketDescription
    if (outDataPacketDescription != NULL) {
        _currentAudioStreamPacketDescription.mStartOffset = 0;
        _currentAudioStreamPacketDescription.mDataByteSize = _currentBufferList.mBuffers[0].mDataByteSize;
        _currentAudioStreamPacketDescription.mVariableFramesInPacket = 0;
        *outDataPacketDescription = &_currentAudioStreamPacketDescription;
    }
    
    *ioNumberDataPackets = 1;
    return noErr;
}

- (instancetype)initWithOutputFormat:(AVAudioFormat *)outputFormat sourceFormat:(AVAudioFormat *)sourceFormat {
    self = [super init];
    if (self) {
        _outputFormat = outputFormat;
        _sourceFormat = sourceFormat;
        
        _converter = nil;
        _currentAudioBlockBuffer = nil;
    }
    return self;
}

- (instancetype)init {
    return [self initWithOutputFormat:[VCAudioConverter defaultAACFormat] sourceFormat:[VCAudioConverter defaultPCMFormat]];
}

- (void)dealloc {
    if (_converter != NULL) {
        AudioConverterReset(_converter);
        AudioConverterDispose(_converter);
        _converter = NULL;
    }
    
    if (_currentAudioBlockBuffer != NULL) {
        CFRelease(_currentAudioBlockBuffer);
        _currentAudioBlockBuffer = NULL;
    }
}

- (AudioConverterRef)converter {
    if (_converter != NULL) {
        return _converter;
    }
    const AudioStreamBasicDescription *sourceDesc = self.sourceFormat.streamDescription;
    const AudioStreamBasicDescription *outputDesc = self.outputFormat.streamDescription;
    
    AudioClassDescription hardwareClassDesc = [self converterClassDescriptionWithManufacturer:kAppleHardwareAudioCodecManufacturer];
    AudioClassDescription softwareClassDesc = [self converterClassDescriptionWithManufacturer:kAppleSoftwareAudioCodecManufacturer];
    
    AudioClassDescription classDescs[] = {hardwareClassDesc, softwareClassDesc};
    
    OSStatus ret = AudioConverterNewSpecific(sourceDesc, outputDesc, sizeof(classDescs), classDescs, &_converter);
    if (ret != noErr) {
        return nil;
    }
    return _converter;
}

- (AudioClassDescription)converterClassDescriptionWithManufacturer:(OSType)manufacturer {
    AudioClassDescription desc;
    if (self.sourceFormat.streamDescription->mFormatID == kAudioFormatLinearPCM) {
        // Encoder
        desc.mType = kAudioEncoderComponentType;
        desc.mSubType = self.outputFormat.streamDescription->mFormatID;
    } else {
        // Decoder
        desc.mType = kAudioDecoderComponentType;
        desc.mSubType = self.sourceFormat.streamDescription->mFormatID;
    }
    desc.mManufacturer = manufacturer;
    return desc;
}

- (void)setOutputFormat:(AVAudioFormat *)outputFormat {
    if ([_outputFormat isEqual:outputFormat] ||
        outputFormat == nil) {
        return;
    }
    _outputFormat = outputFormat;
    if (_converter != nil) {
        AudioConverterDispose(_converter);
    }
    _converter = nil;
}

- (void)setSourceFormat:(AVAudioFormat *)sourceFormat {
    if ([_sourceFormat isEqual:sourceFormat] ||
        sourceFormat == nil) {
        return;
    }
    _sourceFormat = sourceFormat;
    if (_converter != nil) {
        AudioConverterDispose(_converter);
    }
    _converter = nil;
}

- (NSUInteger)maxBufferSize {
    if (self.outputFormat.streamDescription->mFormatID == kAudioFormatLinearPCM) {
        return 1024 * self.outputFormat.streamDescription->mBytesPerFrame;
    } else {
        return 10240;
    }
}

- (NSUInteger)ioOutputDataPacketSize {
    if (self.outputFormat.streamDescription->mFormatID == kAudioFormatLinearPCM) {
        return 1024;
    } else {
        return 10240;
    }
}

- (AVAudioBuffer *)createOutputAudioBufferWithAudioBufferList:(AudioBufferList *)audioBufferList
                                               dataPacketSize:(NSUInteger)dataPacketSizse {
    if (self.outputFormat.streamDescription->mFormatID == kAudioFormatLinearPCM) {
        // 如果声道数大于2 此方法返回nil
        AVAudioPCMBuffer *pcmBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:self.outputFormat frameCapacity:(AVAudioFrameCount)self.maxBufferSize];
        for (int i = 0; i < audioBufferList->mNumberBuffers; ++i) {
            // 注意这个ioOutoutDataPacketSize 是转换后实际有效PCM音频大小
            // 可以将outputBufferList每个buffer大小修改为1024，可以发现转换后的ioOutputDataPacketSize变了；
            memcpy(pcmBuffer.floatChannelData[i], audioBufferList->mBuffers[i].mData, audioBufferList->mBuffers[i].mDataByteSize);
        }
        // frameLength 为有效PCM数据
        pcmBuffer.frameLength = (AVAudioFrameCount)dataPacketSizse;
        return pcmBuffer;
    }
    
    AVAudioCompressedBuffer *compressedBuffer = [[AVAudioCompressedBuffer alloc] initWithFormat:self.outputFormat packetCapacity:(AVAudioFrameCount)self.maxBufferSize];
    for (int i = 0; i < audioBufferList->mNumberBuffers; ++i) {
        memcpy(compressedBuffer.data, audioBufferList->mBuffers[i].mData, audioBufferList->mBuffers[i].mDataByteSize);
    }
    compressedBuffer.packetCount = (AVAudioFrameCount)dataPacketSizse;
    return compressedBuffer;
}

- (OSStatus)convertSampleBuffer:(VCSampleBuffer *)sampleBuffer {
    if (self.converter == nil) return -1;
    
    UInt32 channels = self.sourceFormat.channelCount;
    OSStatus ret = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer.sampleBuffer,
                                                                           NULL,
                                                                           &_currentBufferList,
                                                                           sizeof(_currentBufferList),
                                                                           kCFAllocatorDefault,
                                                                           kCFAllocatorDefault,
                                                                           0,
                                                                           &_currentAudioBlockBuffer);
    
    if (ret != noErr) {
        return ret;
    }
    
    UInt32 maxBufferSize = (UInt32)self.maxBufferSize;
    UInt32 ioOutputDataPacketSize = (UInt32)self.ioOutputDataPacketSize;
    
    AudioBufferList *outputBufferList = (AudioBufferList *)malloc(sizeof(AudioBufferList) + channels * sizeof(AudioBuffer));
    outputBufferList->mNumberBuffers = channels;
    for (int i = 0; i < channels; ++i) {
        outputBufferList->mBuffers[i].mNumberChannels = i;
        outputBufferList->mBuffers[i].mDataByteSize = maxBufferSize;
        outputBufferList->mBuffers[i].mData = malloc(maxBufferSize);
    }
    
    ret = AudioConverterFillComplexBuffer(self.converter,
                                          audioConverterInputDataProc,
                                          (__bridge void *)self,
                                          &ioOutputDataPacketSize,
                                          outputBufferList,
                                          NULL);
    if (ret != noErr) {
        return ret;
    }
    
    AVAudioBuffer *audioBuffer = [self createOutputAudioBufferWithAudioBufferList:outputBufferList dataPacketSize:ioOutputDataPacketSize];
    if (self.delegate &&
        [self.delegate respondsToSelector:@selector(converter:didOutputAudioBuffer:presentationTimeStamp:)]) {
        [self.delegate converter:self didOutputAudioBuffer:audioBuffer presentationTimeStamp:sampleBuffer.presentationTimeStamp];
    }
    
    for (int i = 0; i < channels; ++i) {
        free(outputBufferList->mBuffers[i].mData);
    }
    free(outputBufferList);
    
    if (_currentAudioBlockBuffer != NULL) {
        CFRelease(_currentAudioBlockBuffer);
        _currentAudioBlockBuffer = NULL;
    }
    
    return noErr;
}

- (void)reset {
    AudioConverterReset(self.converter);
}

+ (AVAudioFormat *)AACFormatWithSampleRate:(Float64)sampleRate
                               formatFlags:(AudioFormatFlags)flags
                                  channels:(UInt32)channels {
    AudioStreamBasicDescription basicDescription;
    basicDescription.mFormatID = kAudioFormatMPEG4AAC;
    basicDescription.mSampleRate = sampleRate;
    basicDescription.mFormatFlags = flags;
    basicDescription.mBytesPerFrame = 0;
    basicDescription.mFramesPerPacket = 1024;
    basicDescription.mBytesPerPacket = 0;
    basicDescription.mChannelsPerFrame = channels;
    basicDescription.mBitsPerChannel = 0;
    basicDescription.mReserved = 0;
    
    CMAudioFormatDescriptionRef outputDescription = nil;
    OSStatus ret = CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &basicDescription, 0, NULL, 0, NULL, NULL, &outputDescription);
    if (ret != noErr) {
        return nil;
    }
    
    AVAudioFormat *format = [[AVAudioFormat alloc] initWithCMAudioFormatDescription:outputDescription];
    CFRelease(outputDescription);
    
    return format;
}

+ (AVAudioFormat *)formatWithCMAudioFormatDescription:(CMAudioFormatDescriptionRef)audioFormatDescription {
    AVAudioFormat *format = [[AVAudioFormat alloc] initWithCMAudioFormatDescription:audioFormatDescription];
    return format;
}

+ (AVAudioFormat *)PCMFormatWithSampleRate:(Float64)sampleRate
                                  channels:(UInt32)channels {
    AudioChannelLayoutTag channelLayoutTag = kAudioChannelLayoutTag_Stereo;
    if (channels == 1) {
        channelLayoutTag = kAudioChannelLayoutTag_Mono;
    } else if (channels == 2) {
        channelLayoutTag = kAudioChannelLayoutTag_Stereo;
    } else if (channels == 3) {
        channelLayoutTag = kAudioChannelLayoutTag_AAC_3_0;
    } else if (channels == 4) {
        channelLayoutTag = kAudioChannelLayoutTag_AAC_4_0;
    } else if (channels == 5) {
        channelLayoutTag = kAudioChannelLayoutTag_AAC_5_0;
    } else if (channels == 6) {
        channelLayoutTag = kAudioChannelLayoutTag_AAC_5_1;
    }
    AVAudioChannelLayout *layout = [[AVAudioChannelLayout alloc] initWithLayoutTag:channelLayoutTag];
    AVAudioFormat *format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:sampleRate interleaved:NO channelLayout:layout];
    return format;
}

+ (AVAudioFormat *)defaultPCMFormat {
    return [VCAudioConverter PCMFormatWithSampleRate:44100 channels:2];
}

+ (AVAudioFormat *)defaultAACFormat {
    return [VCAudioConverter AACFormatWithSampleRate:44100 formatFlags:kMPEG4Object_AAC_LC channels:2];
}

@end