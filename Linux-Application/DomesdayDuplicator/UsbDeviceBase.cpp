
#include "UsbDeviceBase.h"
#ifdef _WIN32
#include <memoryapi.h>
#else
#include <sched.h>
#include <sys/mman.h>
#endif
#include <iostream>
#include <thread>
#include <functional>
#include <cassert>

//----------------------------------------------------------------------------------------------------------------------
// Constructors
//----------------------------------------------------------------------------------------------------------------------
UsbDeviceBase::UsbDeviceBase(const ILogger& log)
:log(log)
{ }

//----------------------------------------------------------------------------------------------------------------------
UsbDeviceBase::~UsbDeviceBase()
{ }

//----------------------------------------------------------------------------------------------------------------------
bool UsbDeviceBase::Initialize(uint16_t vendorId, uint16_t productId)
{
    // Attempt to retrieve the initial process working set allocation
#ifdef _WIN32
    BOOL getProcessWorkingSetSizeReturn = GetProcessWorkingSetSize(GetCurrentProcess(), &originalProcessMinimumWorkingSetSizeInBytes, &originalProcessMaximumWorkingSetSizeInBytes);
    if (getProcessWorkingSetSizeReturn == 0)
    {
        DWORD lastError = GetLastError();
        Log().Error("GetProcessWorkingSetSize failed with error code {0}", lastError);
        return false;
    }
#endif
    return true;
}

//----------------------------------------------------------------------------------------------------------------------
// Log methods
//----------------------------------------------------------------------------------------------------------------------
const ILogger& UsbDeviceBase::Log() const
{
    return log;
}

//----------------------------------------------------------------------------------------------------------------------
// Device methods
//----------------------------------------------------------------------------------------------------------------------
void UsbDeviceBase::SendConfigurationCommand(const std::string& preferredDevicePath, bool testMode)
{
    // Bit 0: Set test mode
    // Bit 1: Unused
    // Bit 2: Unused
    // Bit 3: Unused
    // Bit 4: Unused
    uint16_t configurationFlags = 0b00000;
    configurationFlags |= (testMode ? 0b00001 : 0b00000);
    SendVendorSpecificCommand(preferredDevicePath, 0xB6, configurationFlags);
}

//----------------------------------------------------------------------------------------------------------------------
// Capture methods
//----------------------------------------------------------------------------------------------------------------------
bool UsbDeviceBase::StartCapture(const std::filesystem::path& filePath, CaptureFormat format, const std::string& preferredDevicePath, bool isTestMode, bool useSmallUsbTransfers, bool useAsyncFileIo, size_t usbTransferQueueSizeInBytes, size_t diskBufferQueueSizeInBytes)
{
    // If we're already performing a capture, abort any further processing.
    if (transferInProgress)
    {
        Log().Error("StartCapture(): Capture was currently in progress");
        return false;
    }

    // Attempt to connect to the target device
    if (!ConnectToDevice(preferredDevicePath))
    {
        Log().Error("StartCapture(): Failed to connect to the target device");
        captureResult = TransferResult::ConnectionFailure;
        return false;
    }

    // Flag whether we should be using asynchronous IO (Windows only)
#ifdef _WIN32
    useWindowsOverlappedFileIo = useAsyncFileIo;
#endif

    // Attempt to create/open the output file
#ifdef _WIN32
    if (useWindowsOverlappedFileIo)
    {
        windowsCaptureOutputFileHandle = CreateFileW(filePath.wstring().c_str(), GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS, FILE_FLAG_SEQUENTIAL_SCAN | FILE_FLAG_WRITE_THROUGH | FILE_FLAG_OVERLAPPED, NULL);
        if (windowsCaptureOutputFileHandle == INVALID_HANDLE_VALUE)
        {
            DWORD lastError = GetLastError();
            Log().Error("CreateFileW returned {0} with error code {1}.", windowsCaptureOutputFileHandle, lastError);
            captureResult = TransferResult::FileCreationError;
            return false;
        }
    }
    else
    {
#endif
        captureOutputFile.clear();
        captureOutputFile.rdbuf()->pubsetbuf(0, 0);
        captureOutputFile.open(filePath, std::ios::out | std::ios::trunc | std::ios::binary);
        if (!captureOutputFile.is_open())
        {
            Log().Error("StartCapture(): Failed to create the output file at path {0}", filePath);
            captureResult = TransferResult::FileCreationError;
            return false;
        }
#ifdef _WIN32
    }
#endif

    // Create audio WAV file with same base name as RF file
    audioFilePath = filePath;
    audioFilePath.replace_extension(".audio.wav");

    audioOutputFile.clear();
    audioOutputFile.open(audioFilePath, std::ios::out | std::ios::trunc | std::ios::binary);
    if (!audioOutputFile.is_open())
    {
        Log().Error("StartCapture(): Failed to create audio output file at path {0}", audioFilePath);
        captureResult = TransferResult::FileCreationError;
        captureOutputFile.close();
        return false;
    }

    // Write WAV header (will be updated with final sizes on close)
    struct WavHeader {
        char riff[4] = {'R','I','F','F'};
        uint32_t fileSize = 0;  // Will update on close
        char wave[4] = {'W','A','V','E'};
        char fmt[4] = {'f','m','t',' '};
        uint32_t fmtSize = 16;
        uint16_t audioFormat = 1;  // PCM
        uint16_t numChannels = 2;  // Stereo
        uint32_t sampleRate = 78125;
        uint32_t byteRate = 78125 * 2 * 2;  // sampleRate * channels * bytesPerSample
        uint16_t blockAlign = 4;  // channels * bytesPerSample
        uint16_t bitsPerSample = 16;
        char data[4] = {'d','a','t','a'};
        uint32_t dataSize = 0;  // Will update on close
    };

    WavHeader header;
    audioOutputFile.write(reinterpret_cast<const char*>(&header), sizeof(header));

    if (!audioOutputFile.good())
    {
        Log().Error("StartCapture(): Failed to write audio WAV header");
        captureResult = TransferResult::FileCreationError;
        audioOutputFile.close();
        captureOutputFile.close();
        return false;
    }

    Log().Info("StartCapture(): Audio file created: {0}", audioFilePath.string());

    // Create 24-bit PCM audio WAV file for PCM1802
    audio24FilePath = filePath;
    audio24FilePath.replace_extension(".audio24.wav");

    audio24OutputFile.clear();
    audio24OutputFile.open(audio24FilePath, std::ios::out | std::ios::trunc | std::ios::binary);
    if (!audio24OutputFile.is_open())
    {
        Log().Error("StartCapture(): Failed to create 24-bit audio output file at path {0}", audio24FilePath);
        captureResult = TransferResult::FileCreationError;
        audioOutputFile.close();
        captureOutputFile.close();
        return false;
    }

    struct WavHeader24 {
        char riff[4] = {'R','I','F','F'};
        uint32_t fileSize = 0;
        char wave[4] = {'W','A','V','E'};
        char fmt[4] = {'f','m','t',' '};
        uint32_t fmtSize = 16;
        uint16_t audioFormat = 1;  // PCM
        uint16_t numChannels = 2;
        uint32_t sampleRate = 78125;
        uint32_t byteRate = 78125 * 2 * 3; // 3 bytes per sample
        uint16_t blockAlign = 6;
        uint16_t bitsPerSample = 24;
        char data[4] = {'d','a','t','a'};
        uint32_t dataSize = 0;
    };

    WavHeader24 header24;
    audio24OutputFile.write(reinterpret_cast<const char*>(&header24), sizeof(header24));
    if (!audio24OutputFile.good())
    {
        Log().Error("StartCapture(): Failed to write 24-bit audio WAV header");
        captureResult = TransferResult::FileCreationError;
        audio24OutputFile.close();
        audioOutputFile.close();
        captureOutputFile.close();
        return false;
    }
    Log().Info("StartCapture(): 24-bit audio file created: {0}", audio24FilePath.string());

    // Calculate the optimal read buffer size and number of disk buffers, and initialize the structures. We use an
    // unusual case of wrapping an array new into a unique_ptr rather than std::vector here, as we have an atomic_flag
    // member in the structure which can't be moved.
    CalculateDesiredBufferCountAndSize(useSmallUsbTransfers, usbTransferQueueSizeInBytes, diskBufferQueueSizeInBytes, totalDiskBufferEntryCount, diskBufferSizeInBytes);
    diskBufferEntries.reset(new DiskBufferEntry[totalDiskBufferEntryCount]);
    for (size_t i = 0; i < totalDiskBufferEntryCount; ++i)
    {
        DiskBufferEntry& entry = diskBufferEntries[i];
        entry.readBuffer.resize(diskBufferSizeInBytes);
        entry.isDiskBufferFull.clear();
#ifdef _WIN32
        entry.diskWriteInProgress = false;
        if (useWindowsOverlappedFileIo)
        {
            entry.diskWriteOverlappedBuffer = {};
            entry.diskWriteOverlappedBuffer.hEvent = CreateEventW(NULL, TRUE, FALSE, NULL);
        }
#endif
    }

    // Record the capture settings
    captureFilePath = filePath;
    captureFormat = format;
    captureIsTestMode = isTestMode;
    currentUsbTransferQueueSizeInBytes = usbTransferQueueSizeInBytes;
    currentUseSmallUsbTransfers = useSmallUsbTransfers;

    // Initialize capture status
    transferInProgress = true;
    captureResult = TransferResult::Running;
    transferCount = 0;
    transferBufferWrittenCount = 0;
    transferFileSizeWrittenInBytes = 0;
    processedSampleCount = 0;
    minSampleValue = std::numeric_limits<decltype(minSampleValue.load())>::max();
    maxSampleValue = 0;
    clippedMinSampleCount = 0;
    clippedMaxSampleCount = 0;
    recentMinSampleValue = std::numeric_limits<decltype(recentMinSampleValue.load())>::max();
    recentMaxSampleValue = 0;
    recentClippedMinSampleCount = 0;
    recentClippedMaxSampleCount = 0;
    captureThreadStopRequested.clear();
    captureThreadRunning.test_and_set();
    captureThreadRunning.notify_all();

    // Initialize our sequence/test data check state
    sequenceState = SequenceState::Sync;
    savedSequenceCounter = 0;
    expectedNextTestDataValue.reset();
    testDataMax.reset();

    // Initialize audio capture state
    audioSyncLocked = false;
    audioFrameCount = 0;
    audioFileSizeWrittenInBytes = 0;
    audioFrameOffset = 0;
    audioLeftBuffer.clear();
    audioRightBuffer.clear();
    audioLeftBuffer.reserve(2048);
    audioRightBuffer.reserve(2048);
    audio24FrameCount = 0;
    audio24FileSizeWrittenInBytes = 0;
    audio24LeftBuffer.clear();
    audio24RightBuffer.clear();
    audio24LeftBuffer.reserve(2048);
    audio24RightBuffer.reserve(2048);

    // Spin up a thread to handle the execution of the capture process from here on
    std::thread captureThread(std::bind(std::mem_fn(&UsbDeviceBase::CaptureThread), this));
    captureThread.detach();
    return true;
}

//----------------------------------------------------------------------------------------------------------------------
void UsbDeviceBase::StopCapture()
{
    // If a transfer isn't currently in progress, abort any further processing.
    if (!transferInProgress)
    {
        Log().Error("StopCapture(): No capture was currently in progress");
        return;
    }

    // Instruct the capture thread to terminate, and wait for confirmation that it has stopped.
    captureThreadStopRequested.test_and_set();
    captureThreadStopRequested.notify_all();
    captureThreadRunning.wait(true);

    // Release our memory holding the disk buffers
#ifdef _WIN32
    if (useWindowsOverlappedFileIo)
    {
        for (size_t i = 0; i < totalDiskBufferEntryCount; ++i)
        {
            DiskBufferEntry& entry = diskBufferEntries[i];
            CloseHandle(entry.diskWriteOverlappedBuffer.hEvent);
        }
    }
#endif
    diskBufferEntries.reset();

    // Close the output file
#ifdef _WIN32
    if (useWindowsOverlappedFileIo)
    {
        BOOL closeHandleReturn = CloseHandle(windowsCaptureOutputFileHandle);
        if (closeHandleReturn == 0)
        {
            DWORD lastError = GetLastError();
            Log().Error("CloseHandle failed with error code {0}.", lastError);
        }
    }
    else
    {
#endif
        captureOutputFile.close();
#ifdef _WIN32
    }
#endif

    // Finalize and close the audio WAV file
    if (audioOutputFile.is_open())
    {
        FinalizeAudioWavFile();
    }

    // Finalize and close 24-bit audio WAV file
    if (audio24OutputFile.is_open())
    {
        FinalizeAudio24WavFile();
    }

    // Disconnect from the target device
    DisconnectFromDevice();

    // Record that the capture process has completed
    Log().Info("StopCapture(): Ended capture process");
    transferInProgress = false;
}

//----------------------------------------------------------------------------------------------------------------------
void UsbDeviceBase::CaptureThread()
{
    // Determine how large our conversion buffers need to be based on the disk buffer size and the capture format
    size_t requiredConversionBufferSize = 0;
    switch (captureFormat)
    {
    case CaptureFormat::Signed16Bit:
        requiredConversionBufferSize = diskBufferSizeInBytes;
        break;
    case CaptureFormat::Unsigned10Bit:
        requiredConversionBufferSize = (diskBufferSizeInBytes / 8) * 5;
        break;
    case CaptureFormat::Unsigned10Bit4to1Decimation:
        requiredConversionBufferSize = (diskBufferSizeInBytes / (8 * 4)) * 5;
        break;
    }

    // Allocate our conversion buffers
    for (size_t i = 0; i < conversionBufferCount; ++i)
    {
        conversionBuffers[i].resize(requiredConversionBufferSize);
    }

    // Lock all the critical structures into physical memory. This stops these buffers getting paged out, which could
    // cause page faults and lead to missed data packets.
    for (size_t i = 0; i < conversionBufferCount; ++i)
    {
        LockMemoryBufferIntoPhysicalMemory(conversionBuffers[i].data(), conversionBuffers[i].size());
    }
    for (size_t i = 0; i < totalDiskBufferEntryCount; ++i)
    {
        DiskBufferEntry& entry = diskBufferEntries[i];
        LockMemoryBufferIntoPhysicalMemory(entry.readBuffer.data(), entry.readBuffer.size());
    }
    LockMemoryBufferIntoPhysicalMemory(diskBufferEntries.get(), sizeof(diskBufferEntries[0]) * totalDiskBufferEntryCount);
    LockMemoryBufferIntoPhysicalMemory(this, sizeof(*this));

    // Attempt to boost the process priority to realtime
    boostedProcessPriority = SetCurrentProcessRealtimePriority(processPriorityRestoreInfo);
    if (!boostedProcessPriority)
    {
        Log().Warning("CaptureThread(): Failed to boost process priority");
    }

    // Record that a capture process is starting
    Log().Info("CaptureThread(): Starting capture process");

    usbTransferRunning.test_and_set();
    processingRunning.test_and_set();
    usbTransferStopRequested.clear();
    processingStopRequested.clear();
    dumpAllCaptureDataInProgress.clear();
    usbTransferResult = TransferResult::Running;
    processingResult = TransferResult::Running;

    // Start a worker thread to process data after it's read
    std::thread processingThread(std::bind(std::mem_fn(&UsbDeviceBase::ProcessingThread), this));

    // Start a worker thread to transfer data from the USB device
    std::thread usbTransferThread(std::bind(std::mem_fn(&UsbDeviceBase::UsbTransferThread), this));

    // Run transfer continously until we're signalled to stop for some reason
    captureThreadStopRequested.wait(false);

    // Wind up the capture process, latching the appropriate result if an error has occurred.
    TransferResult result = TransferResult::ProgramError;
    bool errorCodeLatched = false;
    bool usbTransferFailed = false;
    bool usbTransferResultChecked = false;
    bool processingFailed = false;
    bool processingResultChecked = false;
    while (usbTransferRunning.test() || processingRunning.test())
    {
        // Check for a USB transfer failure
        if (!usbTransferResultChecked && !usbTransferRunning.test())
        {
            auto transferResultTemp = usbTransferResult.load();
            if (transferResultTemp == TransferResult::Running)
            {
                if (!errorCodeLatched)
                {
                    result = TransferResult::ProgramError;
                    errorCodeLatched = true;
                }
                usbTransferFailed = true;
            }
            else if (transferResultTemp != TransferResult::Success)
            {
                if (!errorCodeLatched)
                {
                    result = transferResultTemp;
                    errorCodeLatched = true;
                }
                usbTransferFailed = true;
            }
            usbTransferResultChecked = true;
        }

        // Check for a data processing failure
        if (!processingResultChecked && !processingRunning.test())
        {
            auto transferResultTemp = processingResult.load();
            if (transferResultTemp == TransferResult::Running)
            {
                if (!errorCodeLatched)
                {
                    result = TransferResult::ProgramError;
                    errorCodeLatched = true;
                }
                processingFailed = true;
            }
            else if (transferResultTemp != TransferResult::Success)
            {
                if (!errorCodeLatched)
                {
                    result = transferResultTemp;
                    errorCodeLatched = true;
                }
                processingFailed = true;
            }
            processingResultChecked = true;
        }

        // Request the USB transfer child worker thread to stop. If no errors have occurred or occur during the final
        // stages, this should cause it to emit all remaining queued transfers and stop gracefully.
        usbTransferStopRequested.test_and_set();
        usbTransferStopRequested.notify_all();

        // Request the processing child worker thread to stop if the USB transfer worker thread has completed, or if an
        // error has occurred. This should cause it to process all queued disk buffers and stop gracefully. We pad out
        // any empty disk buffers as being dumped, and signal their completion, to unblock the worker thread in case
        // it's currently waiting on the next buffer.
        if (!usbTransferRunning.test() || usbTransferFailed || processingFailed)
        {
            processingStopRequested.test_and_set();
            processingStopRequested.notify_all();
            for (size_t i = 0; i < totalDiskBufferEntryCount; ++i)
            {
                DiskBufferEntry& entry = diskBufferEntries[i];
                if (!entry.isDiskBufferFull.test())
                {
                    entry.dumpingBuffer.test_and_set();
                    entry.isDiskBufferFull.test_and_set();
                    entry.isDiskBufferFull.notify_all();
                }
            }
        }

        // If an error occurred, force our worker threads to unblock and dump any data currently in the buffers.
        if (usbTransferFailed || processingFailed)
        {
            dumpAllCaptureDataInProgress.test_and_set();
            for (size_t i = 0; i < totalDiskBufferEntryCount; ++i)
            {
                DiskBufferEntry& entry = diskBufferEntries[i];
                entry.isDiskBufferFull.clear();
                entry.isDiskBufferFull.notify_all();
            }
            for (size_t i = 0; i < totalDiskBufferEntryCount; ++i)
            {
                DiskBufferEntry& entry = diskBufferEntries[i];
                entry.isDiskBufferFull.test_and_set();
                entry.isDiskBufferFull.notify_all();
            }
        }

        // Yield the remainder of the timeslice, to help keep CPU resources free while we try and spin down.
#ifdef _WIN32
        Sleep(0);
#else
        sched_yield();
#endif
    }

    // Wait for our spawned threads to terminate
    usbTransferThread.join();
    processingThread.join();

    // Set the result of this transfer process
    if (!errorCodeLatched)
    {
        result = TransferResult::Success;
    }
    captureResult = result;

    // Restore the original process priority settings
    if (boostedProcessPriority)
    {
        RestoreCurrentProcessPriority(processPriorityRestoreInfo);
    }

    // Release all our memory buffer locks
    for (size_t i = 0; i < conversionBufferCount; ++i)
    {
        UnlockMemoryBuffer(conversionBuffers[i].data(), conversionBuffers[i].size());
    }
    for (size_t i = 0; i < totalDiskBufferEntryCount; ++i)
    {
        DiskBufferEntry& entry = diskBufferEntries[i];
        UnlockMemoryBuffer(entry.readBuffer.data(), entry.readBuffer.size());
    }
    UnlockMemoryBuffer(diskBufferEntries.get(), sizeof(diskBufferEntries[0]) * totalDiskBufferEntryCount);
    UnlockMemoryBuffer(this, sizeof(*this));

    // Flag that this thread is no longer running
    captureThreadRunning.clear();
    captureThreadRunning.notify_all();
}

//----------------------------------------------------------------------------------------------------------------------
bool UsbDeviceBase::GetTransferInProgress() const
{
    return transferInProgress && (captureResult == TransferResult::Running);
}

//----------------------------------------------------------------------------------------------------------------------
UsbDeviceBase::TransferResult UsbDeviceBase::GetTransferResult() const
{
    return captureResult;
}

//----------------------------------------------------------------------------------------------------------------------
size_t UsbDeviceBase::GetNumberOfTransfers() const
{
    return transferCount;
}

//----------------------------------------------------------------------------------------------------------------------
size_t UsbDeviceBase::GetNumberOfDiskBuffersWritten() const
{
    return transferBufferWrittenCount;
}

//----------------------------------------------------------------------------------------------------------------------
size_t UsbDeviceBase::GetFileSizeWrittenInBytes() const
{
    return transferFileSizeWrittenInBytes;
}

//----------------------------------------------------------------------------------------------------------------------
size_t UsbDeviceBase::GetProcessedSampleCount() const
{
    return processedSampleCount;
}

//----------------------------------------------------------------------------------------------------------------------
size_t UsbDeviceBase::GetMinSampleValue() const
{
    return minSampleValue;
}

//----------------------------------------------------------------------------------------------------------------------
size_t UsbDeviceBase::GetMaxSampleValue() const
{
    return maxSampleValue;
}

//----------------------------------------------------------------------------------------------------------------------
size_t UsbDeviceBase::GetClippedMinSampleCount() const
{
    return clippedMinSampleCount;
}

//----------------------------------------------------------------------------------------------------------------------
size_t UsbDeviceBase::GetClippedMaxSampleCount() const
{
    return clippedMaxSampleCount;
}

//----------------------------------------------------------------------------------------------------------------------
size_t UsbDeviceBase::GetRecentMinSampleValue() const
{
    return recentMinSampleValue;
}

//----------------------------------------------------------------------------------------------------------------------
size_t UsbDeviceBase::GetRecentMaxSampleValue() const
{
    return recentMaxSampleValue;
}

//----------------------------------------------------------------------------------------------------------------------
size_t UsbDeviceBase::GetRecentClippedMinSampleCount() const
{
    return recentClippedMinSampleCount;
}

//----------------------------------------------------------------------------------------------------------------------
size_t UsbDeviceBase::GetRecentClippedMaxSampleCount() const
{
    return recentClippedMaxSampleCount;
}

//----------------------------------------------------------------------------------------------------------------------
bool UsbDeviceBase::GetTransferHadSequenceNumbers() const
{
    return (sequenceState != SequenceState::Disabled);
}

//----------------------------------------------------------------------------------------------------------------------
size_t UsbDeviceBase::GetAudioFrameCount() const
{
    return audioFrameCount;
}

//----------------------------------------------------------------------------------------------------------------------
size_t UsbDeviceBase::GetAudioFileSizeWrittenInBytes() const
{
    return audioFileSizeWrittenInBytes;
}

//----------------------------------------------------------------------------------------------------------------------
size_t UsbDeviceBase::GetAudio24FrameCount() const
{
    return audio24FrameCount;
}

//----------------------------------------------------------------------------------------------------------------------
size_t UsbDeviceBase::GetAudio24FileSizeWrittenInBytes() const
{
    return audio24FileSizeWrittenInBytes;
}

//----------------------------------------------------------------------------------------------------------------------
bool UsbDeviceBase::UsbTransferDumpBuffers() const
{
    return dumpAllCaptureDataInProgress.test();
}

//----------------------------------------------------------------------------------------------------------------------
bool UsbDeviceBase::UsbTransferStopRequested() const
{
    return usbTransferStopRequested.test();
}

//----------------------------------------------------------------------------------------------------------------------
UsbDeviceBase::DiskBufferEntry& UsbDeviceBase::GetDiskBuffer(size_t bufferNo)
{
    assert(bufferNo < totalDiskBufferEntryCount);
    return diskBufferEntries[bufferNo];
}

//----------------------------------------------------------------------------------------------------------------------
size_t UsbDeviceBase::GetDiskBufferCount() const
{
    return totalDiskBufferEntryCount;
}

//----------------------------------------------------------------------------------------------------------------------
size_t UsbDeviceBase::GetSingleDiskBufferSizeInBytes() const
{
    return diskBufferSizeInBytes;
}

//----------------------------------------------------------------------------------------------------------------------
size_t UsbDeviceBase::GetUsbTransferQueueSizeInBytes() const
{
    return currentUsbTransferQueueSizeInBytes;
}

//----------------------------------------------------------------------------------------------------------------------
bool UsbDeviceBase::GetUseSmallUsbTransfers() const
{
    return currentUseSmallUsbTransfers;
}

//----------------------------------------------------------------------------------------------------------------------
void UsbDeviceBase::SetUsbTransferFinished(TransferResult result)
{
    usbTransferResult = result;
    usbTransferRunning.clear();
    usbTransferRunning.notify_all();
    captureThreadStopRequested.test_and_set();
    captureThreadStopRequested.notify_all();
}

//----------------------------------------------------------------------------------------------------------------------
void UsbDeviceBase::SetProcessingFinished(TransferResult result)
{
    processingResult = result;
    processingRunning.clear();
    processingRunning.notify_all();
    captureThreadStopRequested.test_and_set();
    captureThreadStopRequested.notify_all();
}

//----------------------------------------------------------------------------------------------------------------------
void UsbDeviceBase::AddCompletedTransferCount(size_t incrementCount)
{
    transferCount += incrementCount;
}

//----------------------------------------------------------------------------------------------------------------------
// Processing methods
//----------------------------------------------------------------------------------------------------------------------
void UsbDeviceBase::ProcessingThread()
{
    ThreadPriorityRestoreInfo priorityRestoreInfo = {};
    bool boostedThreadPriority = SetCurrentThreadRealtimePriority(priorityRestoreInfo);
    std::shared_ptr<void> currentThreadPriorityReducer;
    if (!boostedThreadPriority)
    {
        Log().Warning("ProcessingThread(): Failed to boost thread priority");
    }
    else
    {
        currentThreadPriorityReducer.reset((void*)nullptr, [&](void*) { RestoreCurrentThreadPriority(priorityRestoreInfo); });
    }

    bool transferComplete = false;
    bool processingFailure = false;
    size_t currentDiskBuffer = 0;
    while (!processingFailure && !transferComplete)
    {
        // If processing has been requested to stop, and we've reached the end of the buffered data, or we're being
        // stopped forcefully, break out of the processing loop. Note that if the stop isn't forceful, we let the
        // current loop iteration complete to allow our current pending write to be "flushed" in the case of overlapped
        // disk IO.
        DiskBufferEntry& bufferEntry = diskBufferEntries[currentDiskBuffer];
        bool flushOnly = false;
        if (processingStopRequested.test())
        {
            if (dumpAllCaptureDataInProgress.test())
            {
                transferComplete = true;
                continue;
            }
            if (!bufferEntry.isDiskBufferFull.test() || bufferEntry.dumpingBuffer.test())
            {
                flushOnly = true;
                transferComplete = true;
            }
        }

        // If this isn't a flush-only pass, retrieve, validate, process, and write the next block of data to the output
        // file.
        if (!flushOnly)
        {
            // Wait for the next disk buffer to be filled
            bufferEntry.isDiskBufferFull.wait(false);

            // If the buffer isn't really filled, we've just been woken because the buffer is being dumped while
            // stopping the capture process, loop around again. We expect processing is either being gracefully or
            // forcefully halted. The next loop iteration will allow us to determine what the case is and whether we
            // need to flush pending writes or abort the transfers in flight.
            if (bufferEntry.dumpingBuffer.test())
            {
                continue;
            }

            // Verify and strip the sequence markers from the sample data, and update our sample metrics.
            uint16_t minValue = std::numeric_limits<uint16_t>::max();
            uint16_t maxValue = std::numeric_limits<uint16_t>::min();
            size_t samplesProcessedForBuffer = 0;
            size_t minClippedCount = 0;
            size_t maxClippedCount = 0;
            if (!ProcessSequenceMarkersAndUpdateSampleMetrics(currentDiskBuffer, samplesProcessedForBuffer, minValue, maxValue, minClippedCount, maxClippedCount))
            {
                SetProcessingFinished(TransferResult::SequenceMismatch);
                processingFailure = true;
                continue;
            }
            minSampleValue = std::min(minSampleValue.load(), minValue);
            maxSampleValue = std::max(maxSampleValue.load(), maxValue);
            clippedMinSampleCount += minClippedCount;
            clippedMaxSampleCount += maxClippedCount;
            recentMinSampleValue = minValue;
            recentMaxSampleValue = maxValue;
            recentClippedMinSampleCount = minClippedCount;
            recentClippedMaxSampleCount = maxClippedCount;
            processedSampleCount += samplesProcessedForBuffer;

            // If a buffer sample has been requested, capture it now.
            if (bufferSampleRequestPending.test() && (bufferSamplingRequestedLengthInBytes <= diskBufferSizeInBytes))
            {
                capturedBufferSample.assign(bufferEntry.readBuffer.data(), bufferEntry.readBuffer.data() + bufferSamplingRequestedLengthInBytes);
                bufferSampleRequestPending.clear();
                bufferSampleAvailable.test_and_set();
                bufferSampleAvailable.notify_all();
            }

            // Verify the test data sequence if required
            if (captureIsTestMode && !VerifyTestSequence(currentDiskBuffer))
            {
                SetProcessingFinished(TransferResult::VerificationError);
                processingFailure = true;
                continue;
            }

            // Convert the sample data into the requested data format
            auto& currentConversionBuffer = conversionBuffers[conversionBufferIndex];
            if (!ConvertRawSampleData(currentDiskBuffer, captureFormat, currentConversionBuffer))
            {
                SetProcessingFinished(TransferResult::ProgramError);
                processingFailure = true;
                continue;
            }

            // Write the data to the output file
#ifdef _WIN32
            if (useWindowsOverlappedFileIo)
            {
                // Append to the end of the file using overlapped file IO. The request is queued here, not completed.
                bufferEntry.diskWriteOverlappedBuffer.Offset = 0xFFFFFFFF;
                bufferEntry.diskWriteOverlappedBuffer.OffsetHigh = 0xFFFFFFFF;
                BOOL writeFileReturn = WriteFile(windowsCaptureOutputFileHandle, currentConversionBuffer.data(), (DWORD)currentConversionBuffer.size(), NULL, &bufferEntry.diskWriteOverlappedBuffer);
                DWORD lastError = GetLastError();
                if ((writeFileReturn != 0) || (lastError != ERROR_IO_PENDING))
                {
                    Log().Error("WriteFile returned {0} with error code {1}.", writeFileReturn, lastError);
                    SetProcessingFinished(TransferResult::FileWriteError);
                    processingFailure = true;
                    continue;
                }
                bufferEntry.diskWriteInProgress = true;
            }
            else
            {
#endif
                // Perform the file write in a blocking operation
                captureOutputFile.write((const char*)currentConversionBuffer.data(), currentConversionBuffer.size());
                if (!captureOutputFile.good())
                {
                    Log().Error("ProcessingThread(): An error occurred when writing to the output file");
                    SetProcessingFinished(TransferResult::FileWriteError);
                    processingFailure = true;
                    continue;
                }

                // Mark the disk buffer as empty, notifying the USB transfer thread in case it's blocking waiting for this
                // buffer to be free.
                bufferEntry.isDiskBufferFull.clear();
                bufferEntry.isDiskBufferFull.notify_all();

                // Add the totals from this buffer to the transfer statistics
                ++transferBufferWrittenCount;
                transferFileSizeWrittenInBytes += currentConversionBuffer.size();
#ifdef _WIN32
            }
#endif
        }

        // If we're using overlapped file IO, complete the previously submitted write operation.
#ifdef _WIN32
        if (useWindowsOverlappedFileIo)
        {
            // Retrive the previous disk buffer entry
            size_t lastBufferIndex = (currentDiskBuffer + (totalDiskBufferEntryCount - 1)) % totalDiskBufferEntryCount;
            size_t lastConversionBufferIndex = (conversionBufferIndex + (conversionBufferCount - 1)) % conversionBufferCount;
            DiskBufferEntry& lastBufferEntry = diskBufferEntries[lastBufferIndex];

            // If the previous disk buffer entry had an overlapped write in progress, block waiting for it to complete
            // and check the result.
            if (lastBufferEntry.diskWriteInProgress)
            {
                // Block to check the result of the previous disk write operation
                DWORD bytesTransferred = 0;
                BOOL getOverlappedResultReturn = GetOverlappedResult(windowsCaptureOutputFileHandle, &lastBufferEntry.diskWriteOverlappedBuffer, &bytesTransferred, TRUE);
                if (getOverlappedResultReturn == 0)
                {
                    DWORD lastError = GetLastError();
                    Log().Error("GetOverlappedResult failed with error code {0}.", lastError);
                    SetProcessingFinished(TransferResult::FileWriteError);
                    processingFailure = true;
                    continue;
                }

                // Ensure that the correct number of bytes were written. This should always be the case if it succeeded,
                // but we check anyway.
                auto& lastConversionBuffer = conversionBuffers[lastConversionBufferIndex];
                if (bytesTransferred != lastConversionBuffer.size())
                {
                    Log().Error("ProcessingThread(): Expected {0} bytes written to disk but only {1} bytes were saved from buffer index {2}.", lastConversionBuffer.size(), bytesTransferred, lastBufferIndex);
                    SetProcessingFinished(TransferResult::FileWriteError);
                    processingFailure = true;
                    continue;
                }

                // Mark the previous disk buffer as empty, notifying the USB transfer thread in case it's blocking
                // waiting for this buffer to be free.
                lastBufferEntry.diskWriteInProgress = false;
                lastBufferEntry.isDiskBufferFull.clear();
                lastBufferEntry.isDiskBufferFull.notify_all();

                // Add the totals from this last buffer to the transfer statistics
                ++transferBufferWrittenCount;
                transferFileSizeWrittenInBytes += lastConversionBuffer.size();
            }
        }
#endif

        // Advance to the next disk buffer in the queue
        currentDiskBuffer = (currentDiskBuffer + 1) % totalDiskBufferEntryCount;
#ifdef _WIN32
        if (useWindowsOverlappedFileIo)
        {
            conversionBufferIndex = (conversionBufferIndex + 1) % conversionBufferCount;
        }
#endif
    }

    // If we're using overlapped file IO and a processing failure occurred, cancel any IO operations still in progress
    // on the output file.
#ifdef _WIN32
    if (useWindowsOverlappedFileIo && processingFailure)
    {
        BOOL cancelIoReturn = CancelIo(windowsCaptureOutputFileHandle);
        if (cancelIoReturn == 0)
        {
            DWORD lastError = GetLastError();
            Log().Error("CancelIo failed with error code {0}.", lastError);
        }
    }
#endif

    // If we've been requested to stop the capture process, and an error hasn't been flagged, mark the process as
    // successful.
    if (!processingFailure)
    {
        SetProcessingFinished(TransferResult::Success);
    }
}

//----------------------------------------------------------------------------------------------------------------------
bool UsbDeviceBase::ProcessSequenceMarkersAndUpdateSampleMetrics(size_t diskBufferIndex, size_t& processedSampleCount, uint16_t& minValue, uint16_t& maxValue, size_t& minClippedCount, size_t& maxClippedCount)
{
    // If sequence checking has already failed, return false immediately.
    if (sequenceState == SequenceState::Failed)
    {
        return false;
    }

    // New 96-bit sync pattern broken into 2x 48-bit halves for extraction
    const uint64_t AUDIO_SYNC_PATTERN_LOW48 = 0xDEADBEEFCAFEULL;
    const uint64_t AUDIO_SYNC_PATTERN_HIGH48 = 0xDEADBEEFCAFEULL;
    const uint16_t minPossibleSampleValue = 0;
    const uint16_t maxPossibleSampleValue = 0b1111111111;
    const int COUNTER_SHIFT = 16;
    const uint32_t COUNTER_MAX = 0b111111;
    const size_t SAMPLES_PER_FRAME = 512;
    const size_t BYTES_PER_FRAME = SAMPLES_PER_FRAME * 2;

    uint8_t* diskBuffer = diskBufferEntries[diskBufferIndex].readBuffer.data();
    uint32_t sequenceCounter = savedSequenceCounter;
    size_t bufferSampleCount = diskBufferSizeInBytes / 2;

    // Clear audio buffers at start of processing
    audioLeftBuffer.clear();
    audioRightBuffer.clear();
    audio24LeftBuffer.clear();
    audio24RightBuffer.clear();

    // If we're in sync state, search for the sync pattern
    size_t sampleIndex = 0;
    if (sequenceState == SequenceState::Sync)
    {
        Log().Info("ProcessSequenceMarkersAndUpdateSampleMetrics(): Searching for audio sync pattern...");
        
        // Search through the buffer sample by sample to find the sync pattern
        bool syncFound = false;
        for (size_t searchSample = 0; searchSample <= bufferSampleCount - 512; searchSample++)
        {
            // Check 96-bit sync: first 8 samples (low 48) and next 8 samples (high 48)
            uint64_t syncLow = ExtractSyncPattern(diskBuffer, searchSample * 2);
            uint64_t syncHigh = ExtractSyncPattern(diskBuffer, (searchSample + 8) * 2);
            if (syncLow == AUDIO_SYNC_PATTERN_LOW48 && syncHigh == AUDIO_SYNC_PATTERN_HIGH48)
            {
                // Found the sync pattern! This is the start of a frame
                sampleIndex = searchSample;
                
                // Read the actual sequence number from sample 30 of this frame (first sequence-bearing sample)
                size_t seqSampleOffset = searchSample + 30;
                if (seqSampleOffset < bufferSampleCount)
                {
                    uint32_t actualSeqNum = (uint32_t)(diskBuffer[seqSampleOffset * 2 + 1] >> 2);
                    
                    // Initialize sequence counter: we're at sample 30 of a frame with this sequence number
                    // The sequence counter tracks position within the 4,128,768 sample cycle
                    // We set it so that (sequenceCounter >> 16) gives us the actual sequence number
                    sequenceCounter = (actualSeqNum << COUNTER_SHIFT) | 30;
                    
                    Log().Info("ProcessSequenceMarkersAndUpdateSampleMetrics(): Audio sync locked at sample {0} (byte offset {1}), sequence number = {2}", 
                        searchSample, searchSample * 2, actualSeqNum);
                    
                    sequenceState = SequenceState::Running;
                    audioSyncLocked = true;
                    audioFrameOffset = 0;
                    syncFound = true;
                    break;
                }
            }
        }
        
        if (!syncFound)
        {
            // Didn't find sync pattern in this buffer, process samples without audio extraction
            Log().Trace("ProcessSequenceMarkersAndUpdateSampleMetrics(): Sync pattern not found in this buffer");
            
            // Still need to update RF sample metrics for all samples
            for (size_t i = 0; i < bufferSampleCount; i++)
            {
                size_t byteOffset = i * 2;
                
                // Strip the top 6 bits
                diskBuffer[byteOffset + 1] &= 0x03;
                
                // Extract RF data (lower 10 bits)
                uint16_t rfSample = (uint16_t)diskBuffer[byteOffset] |
                                   ((uint16_t)diskBuffer[byteOffset + 1] << 8);
                
                // Update min/max values
                minValue = std::min(minValue, rfSample);
                maxValue = std::max(maxValue, rfSample);
                
                // Check for clipping
                if (rfSample == minPossibleSampleValue) {
                    ++minClippedCount;
                } else if (rfSample == maxPossibleSampleValue) {
                    ++maxClippedCount;
                }
            }
            
            processedSampleCount += bufferSampleCount;
            savedSequenceCounter = sequenceCounter;
            return true;
        }
    }

    // Process samples starting from sampleIndex, handling frame boundaries
    while (sampleIndex < bufferSampleCount)
    {
        size_t samplesLeftInBuffer = bufferSampleCount - sampleIndex;
        size_t samplesLeftInFrame = SAMPLES_PER_FRAME - audioFrameOffset;
        size_t samplesToProcess = std::min(samplesLeftInBuffer, samplesLeftInFrame);
        
        // If we're at the start of a frame (offset 0), validate sync pattern and sequence number
        if (audioFrameOffset == 0)
        {
            // Validate sync pattern - must be present at start of every frame
            if (samplesLeftInBuffer >= 30)
            {
                uint64_t syncLow = ExtractSyncPattern(diskBuffer, sampleIndex * 2);
                uint64_t syncHigh = ExtractSyncPattern(diskBuffer, (sampleIndex + 8) * 2);
                if (!(syncLow == AUDIO_SYNC_PATTERN_LOW48 && syncHigh == AUDIO_SYNC_PATTERN_HIGH48))
                {
                    Log().Error("ProcessSequenceMarkersAndUpdateSampleMetrics(): Audio sync lost at sample {0}",
                        sampleIndex);
                    sequenceState = SequenceState::Failed;
                    return false;
                }
                
                // // Validate sequence number once per frame (check sample 14)
                // size_t seqSampleOffset = sampleIndex + 14;
                // if (seqSampleOffset < bufferSampleCount)
                // {
                //     uint32_t expectedSeq = sequenceCounter >> COUNTER_SHIFT;
                //     uint32_t actualSeq = (uint32_t)(diskBuffer[seqSampleOffset * 2 + 1] >> 2);
                    
                //     if (actualSeq != expectedSeq)
                //     {
                //         Log().Error("ProcessSequenceMarkersAndUpdateSampleMetrics(): Sequence number mismatch at frame starting at sample {0}! Expecting {1} but got {2}",
                //             sampleIndex, expectedSeq, actualSeq);
                //         sequenceState = SequenceState::Failed;
                //         savedSequenceCounter = sequenceCounter;
                //         return false;
                //     }
                // }
            }
            
            // Extract audio data (samples 8-11 of the frame)
            if (samplesLeftInBuffer >= 30)
            {
                // ADC128 12-bit audio now at samples 16..19
                size_t adc128Offset = sampleIndex + 16;
                uint16_t audioLeftUnsigned = Extract12BitAudio(diskBuffer, adc128Offset * 2, 0);
                uint16_t audioRightUnsigned = Extract12BitAudio(diskBuffer, adc128Offset * 2, 2);
                
                // DEBUG: Log first few samples to see what we're actually getting
                static int debugCount = 0;
                if (debugCount < 10) {
                    //Log().Info("DEBUG: Raw audio values: L={0} (0x{1:X}), R={2} (0x{3:X})", 
                    //    audioLeftUnsigned, audioLeftUnsigned, audioRightUnsigned, audioRightUnsigned);
                    debugCount++;
                }
                
                // Convert from unsigned (0-4095) to signed, centered at 2048
                int16_t audioLeft = (int16_t)audioLeftUnsigned - 2048;
                int16_t audioRight = (int16_t)audioRightUnsigned - 2048;
                
                // Store audio samples in buffer
                audioLeftBuffer.push_back(audioLeft);
                audioRightBuffer.push_back(audioRight);

                // PCM1802 24-bit at samples 22..25 (left) and 26..29 (right)
                uint32_t pcmLeft = Extract24BitTop6x4(diskBuffer, (sampleIndex + 22) * 2);
                uint32_t pcmRight = Extract24BitTop6x4(diskBuffer, (sampleIndex + 26) * 2);
                
                // DEBUG: Extensive logging
                static int pcm_debug3 = 0;
                if (pcm_debug3 < 10) {
                    size_t offL = (sampleIndex + 22) * 2;
                    size_t offR = (sampleIndex + 26) * 2;
                    
                    // Left channel raw bytes
                    uint8_t L_byte0 = diskBuffer[offL + 0];
                    uint8_t L_byte1 = diskBuffer[offL + 1];
                    uint8_t L_byte2 = diskBuffer[offL + 2];
                    uint8_t L_byte3 = diskBuffer[offL + 3];
                    uint8_t L_byte4 = diskBuffer[offL + 4];
                    uint8_t L_byte5 = diskBuffer[offL + 5];
                    uint8_t L_byte6 = diskBuffer[offL + 6];
                    uint8_t L_byte7 = diskBuffer[offL + 7];
                    
                    // Left channel 6-bit extractions
                    uint8_t L_s0 = (L_byte1 >> 2) & 0x3F;
                    uint8_t L_s1 = (L_byte3 >> 2) & 0x3F;
                    uint8_t L_s2 = (L_byte5 >> 2) & 0x3F;
                    uint8_t L_s3 = (L_byte7 >> 2) & 0x3F;
                    
                    // Right channel 6-bit extractions
                    uint8_t R_s0 = (diskBuffer[offR + 1] >> 2) & 0x3F;
                    uint8_t R_s1 = (diskBuffer[offR + 3] >> 2) & 0x3F;
                    uint8_t R_s2 = (diskBuffer[offR + 5] >> 2) & 0x3F;
                    uint8_t R_s3 = (diskBuffer[offR + 7] >> 2) & 0x3F;
                    
                    Log().Info("=== PCM DEBUG Frame {0} ===", pcm_debug3);
                    Log().Info("Left raw bytes: [{0:02X} {1:02X}] [{2:02X} {3:02X}] [{4:02X} {5:02X}] [{6:02X} {7:02X}]",
                        L_byte0, L_byte1, L_byte2, L_byte3, L_byte4, L_byte5, L_byte6, L_byte7);
                    Log().Info("Left 6-bit: s0=0x{0:02X}({0}) s1=0x{1:02X}({1}) s2=0x{2:02X}({2}) s3=0x{3:02X}({3})",
                        L_s0, L_s1, L_s2, L_s3);
                    Log().Info("Left combined: raw=0x{0:X} masked=0x{1:X}", pcmLeft, pcmLeft & 0xFFFFFF);
                    
                    Log().Info("Right 6-bit: s0=0x{0:02X}({0}) s1=0x{1:02X}({1}) s2=0x{2:02X}({2}) s3=0x{3:02X}({3})",
                        R_s0, R_s1, R_s2, R_s3);
                    Log().Info("Right combined: raw=0x{0:X} masked=0x{1:X}", pcmRight, pcmRight & 0xFFFFFF);
                    
                    pcm_debug3++;
                }
                
                // Mask to ensure we only have 24 bits
                pcmLeft &= 0xFFFFFF;
                pcmRight &= 0xFFFFFF;
                
                // Convert from offset binary to signed by subtracting midpoint
                // 24-bit midpoint is 0x800000 (8388608)
                int32_t pcmLeftSigned = (int32_t)pcmLeft - 0x800000;
                int32_t pcmRightSigned = (int32_t)pcmRight - 0x800000;
                
                // DEBUG: Show final signed values
                if (pcm_debug3 <= 10) {
                    Log().Info("Final signed: Left={0} Right={1}", pcmLeftSigned, pcmRightSigned);
                }
                audio24LeftBuffer.push_back(pcmLeftSigned);
                audio24RightBuffer.push_back(pcmRightSigned);
            }
        }
        
        // Update RF sample metrics for all processed samples
        for (size_t i = 0; i < samplesToProcess; i++)
        {
            size_t byteOffset = (sampleIndex + i) * 2;
            
            // Strip the top 6 bits
            diskBuffer[byteOffset + 1] &= 0x03;
            
            // Extract RF data (lower 10 bits)
            uint16_t rfSample = (uint16_t)diskBuffer[byteOffset] |
                               ((uint16_t)diskBuffer[byteOffset + 1] << 8);
            
            // Update min/max values
            minValue = std::min(minValue, rfSample);
            maxValue = std::max(maxValue, rfSample);
            
            // Check for clipping
            if (rfSample == minPossibleSampleValue) {
                ++minClippedCount;
            } else if (rfSample == maxPossibleSampleValue) {
                ++maxClippedCount;
            }
        }
        
        // Advance sequence counter for ALL samples processed (not just sequence number samples)
        // The sequence counter tracks absolute position in the 4,128,768 sample cycle
        sequenceCounter += static_cast<uint32_t>(samplesToProcess);
        if (sequenceCounter >= (COUNTER_MAX << COUNTER_SHIFT))
        {
            sequenceCounter = sequenceCounter % (COUNTER_MAX << COUNTER_SHIFT);
        }
        
        sampleIndex += samplesToProcess;
        audioFrameOffset += samplesToProcess;
        processedSampleCount += samplesToProcess;
        
        // Reset frame offset when we complete a frame
        if (audioFrameOffset >= SAMPLES_PER_FRAME)
        {
            audioFrameOffset = 0;
        }
    }

    // Write audio buffers to WAV files if we have data
    if (!audioLeftBuffer.empty())
    {
        if (!WriteAudioFramesToWav(audioLeftBuffer, audioRightBuffer))
        {
            Log().Error("ProcessSequenceMarkersAndUpdateSampleMetrics(): Failed to write audio frames to WAV file");
            return false;
        }
        audioFrameCount += audioLeftBuffer.size();
    }
    if (!audio24LeftBuffer.empty())
    {
        if (!WriteAudio24FramesToWav(audio24LeftBuffer, audio24RightBuffer))
        {
            Log().Error("ProcessSequenceMarkersAndUpdateSampleMetrics(): Failed to write 24-bit audio frames to WAV file");
            return false;
        }
        audio24FrameCount += audio24LeftBuffer.size();
    }

    // Save the resulting sequence counter so we can continue checking from the same position in the next buffer
    savedSequenceCounter = sequenceCounter;
    return true;
}

//----------------------------------------------------------------------------------------------------------------------
bool UsbDeviceBase::VerifyTestSequence(size_t diskBufferIndex)
{
    // Retrieve the stored expected next sample value. If we haven't processed a buffer in this capture yet,
    // latch the first sample value as the expected value so we can start from here.
    DiskBufferEntry& bufferEntry = diskBufferEntries[diskBufferIndex];
    uint16_t expectedValue = expectedNextTestDataValue.value_or((uint16_t)bufferEntry.readBuffer[0] | (uint16_t)((uint16_t)bufferEntry.readBuffer[1] << 8));

    // Verify each sample in the buffer matches our expected sequence progression
    const uint8_t* readBufferPointer = bufferEntry.readBuffer.data();
    for (size_t i = 0; i < bufferEntry.readBuffer.size(); i += 2)
    {
        // Get the original 10-bit unsigned value from the disk data buffer
        uint16_t actualValue = (uint16_t)readBufferPointer[0] | ((uint16_t)readBufferPointer[1] << 8);
        readBufferPointer += 2;

        // If the actual value doesn't match our expected value, but this is the first time the test sequence
        // has wrapped around to 0, check if this appears to be the wrap point for the sequence, and latch it.
        // Valid wrapp points are either 1021 (newer FPGA firmware) or 1024 (older FPGA firmware).
        if (!testDataMax.has_value() && (expectedValue != actualValue) && (actualValue == 0) && ((expectedValue == 1021) || (expectedValue == 1024)))
        {
            testDataMax = expectedValue;
            expectedValue = 1;
            continue;
        }

        // If the expected value differs from the actual value, log an error.
        if (expectedValue != actualValue)
        {
            // Data error
            Log().Error("VerifyTestSequence(): Data error in test data verification! Expecting {0} but got {1}", expectedValue, actualValue);
            return false;
        }

        // Calculate the value we expect to find for the next sample
        ++expectedValue;
        if (testDataMax.has_value() && (expectedValue == testDataMax))
        {
            expectedValue = 0;
        }
    }

    // Store the next expected sample value so we can check against the next buffer
    expectedNextTestDataValue = expectedValue;
    return true;
}

//----------------------------------------------------------------------------------------------------------------------
bool UsbDeviceBase::ConvertRawSampleData(size_t diskBufferIndex, CaptureFormat captureFormat, std::vector<uint8_t>& outputBuffer) const
{
    const DiskBufferEntry& bufferEntry = diskBufferEntries[diskBufferIndex];
    const uint8_t* readBufferPointer = bufferEntry.readBuffer.data();
    size_t readBufferSizeInBytes = bufferEntry.readBuffer.size();

    // Convert the data to the required format
    uint8_t* writeBufferPointer = outputBuffer.data();
    if (captureFormat == CaptureFormat::Signed16Bit)
    {
        // Translate the data in the disk buffer to scaled 16-bit signed data
        for (size_t i = 0; i < readBufferSizeInBytes; i += 2)
        {
            // Get the original 10-bit unsigned value from the disk data buffer
            uint16_t originalValue = (uint16_t)readBufferPointer[0] | ((uint16_t)readBufferPointer[1] << 8);
            readBufferPointer += 2;

            // Sign and scale the data to 16-bits. Technically a line like this would use the entire 16-bit range:
            //uint16_t signedValue = ((uint16_t)((int16_t)originalValue - 0x0200) << 6) | ((originalValue >> 4) & 0x003F);
            // In our case here however, that would not be preferred, since we can't restore the lost 6 bits of
            // precision, and where we guess wrong we'd create very slight frequency distortions. It's better to leave
            // the data as 10-bit and just shift it up, which doesn't technically preserve the relative mplitude of the
            // signal, but we don't care about the overall amplitude in this case, it's the frequency we care about.
            uint16_t signedValue = (uint16_t)((int16_t)originalValue - 0x0200) << 6;
            writeBufferPointer[0] = (uint8_t)((uint16_t)signedValue & 0x00FF);
            writeBufferPointer[1] = (uint8_t)(((uint16_t)signedValue & 0xFF00) >> 8);
            writeBufferPointer += 2;
        }
    }
    else if (captureFormat == CaptureFormat::Unsigned10Bit)
    {
        // Translate the data in the disk buffer to unsigned 10-bit packed data
        for (size_t i = 0; i < readBufferSizeInBytes; i += 8)
        {
            // Get the original 4 10-bit words
            uint16_t originalWords[4];
            originalWords[0] = (uint16_t)readBufferPointer[0] | ((uint16_t)readBufferPointer[1] << 8);
            originalWords[1] = (uint16_t)readBufferPointer[2] | ((uint16_t)readBufferPointer[3] << 8);
            originalWords[2] = (uint16_t)readBufferPointer[4] | ((uint16_t)readBufferPointer[5] << 8);
            originalWords[3] = (uint16_t)readBufferPointer[6] | ((uint16_t)readBufferPointer[7] << 8);
            readBufferPointer += 8;

            // Convert into 5 bytes of packed 10-bit data
            writeBufferPointer[0] = (uint8_t)((originalWords[0] & 0x03FC) >> 2);
            writeBufferPointer[1] = (uint8_t)((originalWords[0] & 0x0003) << 6) | (uint8_t)((originalWords[1] & 0x03F0) >> 4);
            writeBufferPointer[2] = (uint8_t)((originalWords[1] & 0x000F) << 4) | (uint8_t)((originalWords[2] & 0x03C0) >> 6);
            writeBufferPointer[3] = (uint8_t)((originalWords[2] & 0x003F) << 2) | (uint8_t)((originalWords[3] & 0x0300) >> 8);
            writeBufferPointer[4] = (uint8_t)((originalWords[3] & 0x00FF));
            writeBufferPointer += 5;
        }
    }
    else if (captureFormat == CaptureFormat::Unsigned10Bit4to1Decimation)
    {
        // Translate the data in the disk buffer to unsigned 10-bit packed data with 4:1 decimation
        for (size_t i = 0; i < readBufferSizeInBytes; i += (8 * 4))
        {
            // Get the original 4 10-bit words
            uint16_t originalWords[4];
            originalWords[0] = (uint16_t)readBufferPointer[0 + 0] | ((uint16_t)readBufferPointer[1 + 0] << 8);
            originalWords[1] = (uint16_t)readBufferPointer[2 + 4] | ((uint16_t)readBufferPointer[3 + 4] << 8);
            originalWords[2] = (uint16_t)readBufferPointer[4 + 8] | ((uint16_t)readBufferPointer[5 + 8] << 8);
            originalWords[3] = (uint16_t)readBufferPointer[6 + 12] | ((uint16_t)readBufferPointer[7 + 12] << 8);
            readBufferPointer += 8 * 4;

            // Convert into 5 bytes of packed 10-bit data
            writeBufferPointer[0] = (uint8_t)((originalWords[0] & 0x03FC) >> 2);
            writeBufferPointer[1] = (uint8_t)((originalWords[0] & 0x0003) << 6) | (uint8_t)((originalWords[1] & 0x03F0) >> 4);
            writeBufferPointer[2] = (uint8_t)((originalWords[1] & 0x000F) << 4) | (uint8_t)((originalWords[2] & 0x03C0) >> 6);
            writeBufferPointer[3] = (uint8_t)((originalWords[2] & 0x003F) << 2) | (uint8_t)((originalWords[3] & 0x0300) >> 8);
            writeBufferPointer[4] = (uint8_t)((originalWords[3] & 0x00FF));
            writeBufferPointer += 5;
        }
    }
    else
    {
        Log().Error("ConvertRawSampleData(): Unknown capture format {0} specified", captureFormat);
        return false;
    }
    return true;
}

//----------------------------------------------------------------------------------------------------------------------
// Audio processing methods
//----------------------------------------------------------------------------------------------------------------------

// Extract 48-bit sync pattern from samples 0-7 (6 bits per sample from top 6 bits)
uint64_t UsbDeviceBase::ExtractSyncPattern(uint8_t* buffer, size_t byteOffset) const
{
    uint64_t pattern = 0;
    for (size_t i = 0; i < 8; i++) {
        size_t offset = byteOffset + i * 2;
        uint8_t bits6 = (buffer[offset + 1] >> 2) & 0x3F;
        pattern |= ((uint64_t)bits6 << (i * 6));
    }
    return pattern;
}

// Extract 12-bit audio value from two consecutive samples (6 bits each from top 6 bits)
uint16_t UsbDeviceBase::Extract12BitAudio(uint8_t* buffer, size_t byteOffset, size_t sampleIndex) const
{
    // Extract 12 bits from 2 samples (6 bits each)
    size_t offset1 = byteOffset + sampleIndex * 2;
    size_t offset2 = byteOffset + (sampleIndex + 1) * 2;
    uint8_t high6 = (buffer[offset1 + 1] >> 2) & 0x3F;
    uint8_t low6 = (buffer[offset2 + 1] >> 2) & 0x3F;
    return ((uint16_t)high6 << 6) | (uint16_t)low6;
}

// Extract 24-bit from four consecutive samples' top 6 bits
uint32_t UsbDeviceBase::Extract24BitTop6x4(uint8_t* buffer, size_t byteOffset) const
{
    uint8_t s0 = (buffer[byteOffset + 1] >> 2) & 0x3F;
    uint8_t s1 = (buffer[byteOffset + 3] >> 2) & 0x3F;
    uint8_t s2 = (buffer[byteOffset + 5] >> 2) & 0x3F;
    uint8_t s3 = (buffer[byteOffset + 7] >> 2) & 0x3F;
    return ((uint32_t)s0 << 18) | ((uint32_t)s1 << 12) | ((uint32_t)s2 << 6) | (uint32_t)s3;
}

// Write audio frames to WAV file
bool UsbDeviceBase::WriteAudioFramesToWav(const std::vector<int16_t>& leftSamples, const std::vector<int16_t>& rightSamples)
{
    if (!audioOutputFile.is_open()) {
        return false;
    }

    if (leftSamples.size() != rightSamples.size()) {
        Log().Error("WriteAudioFramesToWav(): Left and right sample counts don't match");
        return false;
    }

    // Write audio frames as 16-bit stereo PCM, interleaved
    for (size_t i = 0; i < leftSamples.size(); i++) {
        // Scale 12-bit signed (-2048 to +2047) to 16-bit signed (-32768 to +32767)
        // Multiply by 16 to use full 16-bit range
        int16_t left16 = leftSamples[i] * 16;
        int16_t right16 = rightSamples[i] * 16;

        // Write little-endian
        audioOutputFile.write(reinterpret_cast<const char*>(&left16), 2);
        audioOutputFile.write(reinterpret_cast<const char*>(&right16), 2);
    }

    audioFileSizeWrittenInBytes += leftSamples.size() * 4; // 2 channels * 2 bytes per sample

    return audioOutputFile.good();
}

// Write 24-bit stereo frames, interleaved (3 bytes per sample, little-endian)
bool UsbDeviceBase::WriteAudio24FramesToWav(const std::vector<int32_t>& leftSamples, const std::vector<int32_t>& rightSamples)
{
    if (!audio24OutputFile.is_open()) {
        return false;
    }
    if (leftSamples.size() != rightSamples.size()) {
        Log().Error("WriteAudio24FramesToWav(): Left and right sample counts don't match");
        return false;
    }
    for (size_t i = 0; i < leftSamples.size(); i++) {
        int32_t l = leftSamples[i];
        int32_t r = rightSamples[i];
        // Clamp to 24-bit signed range and write little-endian 24-bit
        if (l > 0x7FFFFF) l = 0x7FFFFF; if (l < -0x800000) l = -0x800000;
        if (r > 0x7FFFFF) r = 0x7FFFFF; if (r < -0x800000) r = -0x800000;
        uint8_t lb0 = (uint8_t)(l & 0xFF);
        uint8_t lb1 = (uint8_t)((l >> 8) & 0xFF);
        uint8_t lb2 = (uint8_t)((l >> 16) & 0xFF);
        uint8_t rb0 = (uint8_t)(r & 0xFF);
        uint8_t rb1 = (uint8_t)((r >> 8) & 0xFF);
        uint8_t rb2 = (uint8_t)((r >> 16) & 0xFF);
        audio24OutputFile.write((const char*)&lb0, 1);
        audio24OutputFile.write((const char*)&lb1, 1);
        audio24OutputFile.write((const char*)&lb2, 1);
        audio24OutputFile.write((const char*)&rb0, 1);
        audio24OutputFile.write((const char*)&rb1, 1);
        audio24OutputFile.write((const char*)&rb2, 1);
    }
    audio24FileSizeWrittenInBytes += leftSamples.size() * 6;
    return audio24OutputFile.good();
}

// Finalize WAV file by updating header with final sizes
bool UsbDeviceBase::FinalizeAudioWavFile()
{
    if (!audioOutputFile.is_open()) {
        return false;
    }

    // Get current file size
    audioOutputFile.flush();
    std::streampos currentPos = audioOutputFile.tellp();
    size_t totalFileSize = static_cast<size_t>(currentPos);

    // Update RIFF chunk size (file size - 8)
    audioOutputFile.seekp(4);
    uint32_t riffChunkSize = static_cast<uint32_t>(totalFileSize - 8);
    audioOutputFile.write(reinterpret_cast<const char*>(&riffChunkSize), 4);

    // Update data chunk size (file size - 44)
    audioOutputFile.seekp(40);
    uint32_t dataChunkSize = static_cast<uint32_t>(totalFileSize - 44);
    audioOutputFile.write(reinterpret_cast<const char*>(&dataChunkSize), 4);

    audioOutputFile.close();

    Log().Info("Audio file finalized: {0} ({1} frames, {2} bytes)",
        audioFilePath.string(), audioFrameCount.load(), totalFileSize);

    return true;
}

bool UsbDeviceBase::FinalizeAudio24WavFile()
{
    if (!audio24OutputFile.is_open()) {
        return false;
    }
    audio24OutputFile.flush();
    std::streampos currentPos = audio24OutputFile.tellp();
    size_t totalFileSize = static_cast<size_t>(currentPos);
    // Update RIFF chunk size
    audio24OutputFile.seekp(4);
    uint32_t riffChunkSize = static_cast<uint32_t>(totalFileSize - 8);
    audio24OutputFile.write(reinterpret_cast<const char*>(&riffChunkSize), 4);
    // Update data chunk size
    audio24OutputFile.seekp(40);
    uint32_t dataChunkSize = static_cast<uint32_t>(totalFileSize - 44);
    audio24OutputFile.write(reinterpret_cast<const char*>(&dataChunkSize), 4);
    audio24OutputFile.close();
    Log().Info("24-bit audio file finalized: {0} ({1} frames, {2} bytes)",
        audio24FilePath.string(), audio24FrameCount.load(), totalFileSize);
    return true;
}

//----------------------------------------------------------------------------------------------------------------------
// Buffer sampling methods
//----------------------------------------------------------------------------------------------------------------------
void UsbDeviceBase::QueueBufferSampleRequest(size_t requestedSampleLengthInBytes)
{
    bufferSamplingRequestedLengthInBytes = requestedSampleLengthInBytes;
    bufferSampleRequestPending.test_and_set();
}

//----------------------------------------------------------------------------------------------------------------------
bool UsbDeviceBase::GetNextBufferSample(std::vector<uint8_t>& bufferSample)
{
    // If no new buffer sample is available, abort any further processing.
    if (!bufferSampleAvailable.test())
    {
        return false;
    }

    // Copy the requested data into the buffer
    bufferSampleAvailable.clear();
    bufferSample.assign(capturedBufferSample.data(), capturedBufferSample.data() + capturedBufferSample.size());
    return true;
}

//----------------------------------------------------------------------------------------------------------------------
// Utility methods
//----------------------------------------------------------------------------------------------------------------------
bool UsbDeviceBase::LockMemoryBufferIntoPhysicalMemory(void* baseAddress, size_t sizeInBytes)
{
#ifdef _WIN32
    // Retrieve the Windows page allocation size
    SYSTEM_INFO sysInfo;
    GetSystemInfo(&sysInfo);
    size_t systemPageSizeInBytes = (size_t)sysInfo.dwPageSize;

    // Increase the process working set size on Windows, to allow for the extra allocation required by the locked
    // buffers. If we don't do this, VirtualLock will fail if we exceed the initial allocation. Note that since memory
    // allocations may straddle page boundaries, we pad out an extra two memory pages per locked region.
    size_t workingSetSizeIncreaseOverBaseline = (lockedMemorySizeInBytes + sizeInBytes) + (systemPageSizeInBytes * 2 * (lockedMemoryBufferCount + 1));
    size_t newMinWorkingSetSize = originalProcessMinimumWorkingSetSizeInBytes + workingSetSizeIncreaseOverBaseline;
    size_t newMaxWorkingSetSize = originalProcessMaximumWorkingSetSizeInBytes + workingSetSizeIncreaseOverBaseline;
    BOOL setProcessWorkingSetSizeReturn = SetProcessWorkingSetSize(GetCurrentProcess(), newMinWorkingSetSize, newMaxWorkingSetSize);
    if (setProcessWorkingSetSizeReturn == 0)
    {
        DWORD lastError = GetLastError();
        Log().Error("SetProcessWorkingSetSize failed with error code {0}", lastError);
        return false;
    }
#endif

    // Lock the target memory buffer into physical memory
#ifdef _WIN32
    BOOL virtualLockReturn = VirtualLock(baseAddress, sizeInBytes);
    if (virtualLockReturn == 0)
    {
        DWORD lastError = GetLastError();
        Log().Error("VirtualLock failed with error code {0}", lastError);
        return false;
    }
#else
    if (mlock(baseAddress, sizeInBytes) == -1)
    {
        Log().Error("mlock failed");
        return false;
    }
#endif

    // Increase the totals of locked memory
    lockedMemorySizeInBytes += sizeInBytes;
    ++lockedMemoryBufferCount;
    return true;
}

//----------------------------------------------------------------------------------------------------------------------
void UsbDeviceBase::UnlockMemoryBuffer(void* baseAddress, size_t sizeInBytes)
{
    // Release the lock on the target memory buffer
#ifdef _WIN32
    BOOL virtualUnlockReturn = VirtualUnlock(baseAddress, sizeInBytes);
    if (virtualUnlockReturn == 0)
    {
        DWORD lastError = GetLastError();
        Log().Error("VirtualUnlock failed with error code {0}", lastError);
        return;
    }
#else
    munlock(baseAddress, sizeInBytes);
#endif

    // Decrease the totals of locked memory
    lockedMemorySizeInBytes -= sizeInBytes;
    --lockedMemoryBufferCount;

#ifdef _WIN32
    // Retrieve the Windows page allocation size
    SYSTEM_INFO sysInfo;
    GetSystemInfo(&sysInfo);
    size_t systemPageSizeInBytes = (size_t)sysInfo.dwPageSize;

    // Reduce the process working set size on Windows
    size_t workingSetSizeIncreaseOverBaseline = (lockedMemorySizeInBytes + sizeInBytes) + (systemPageSizeInBytes * 2 * (lockedMemoryBufferCount + 1));
    size_t newMinWorkingSetSize = originalProcessMinimumWorkingSetSizeInBytes + workingSetSizeIncreaseOverBaseline;
    size_t newMaxWorkingSetSize = originalProcessMaximumWorkingSetSizeInBytes + workingSetSizeIncreaseOverBaseline;
    BOOL setProcessWorkingSetSizeReturn = SetProcessWorkingSetSize(GetCurrentProcess(), newMinWorkingSetSize, newMaxWorkingSetSize);
    if (setProcessWorkingSetSizeReturn == 0)
    {
        DWORD lastError = GetLastError();
        Log().Error("SetProcessWorkingSetSize failed with error code {0}", lastError);
        return;
    }
#endif
}

//----------------------------------------------------------------------------------------------------------------------
#ifdef _WIN32
bool UsbDeviceBase::SetCurrentProcessRealtimePriority(ProcessPriorityRestoreInfo& priorityRestoreInfo)
{
    // Request the realtime priority class on Windows. If the process doesn't have administrator rights, we may not
    // obtain realtime priority, but in that case the call will still succeed, and give us the highest priority class
    // we can obtain with the current process privileges.
    int originalPriorityClass = GetPriorityClass(GetCurrentProcess());
    int requestedPriorityClass = REALTIME_PRIORITY_CLASS;
    BOOL setPriorityClassReturn = SetPriorityClass(GetCurrentProcess(), requestedPriorityClass);
    if (setPriorityClassReturn == 0)
    {
        DWORD lastError = GetLastError();
        Log().Error("SetPriorityClass failed with error code {0}", lastError);
        return false;
    }

    // Confirm the priority class we ended up obtaining
    int newPriorityClass = GetPriorityClass(GetCurrentProcess());
    priorityRestoreInfo.originalPriorityClass = originalPriorityClass;
    Log().Info("SetCurrentProcessRealtimePriority: Requesting process priority {0} gave us {1}", requestedPriorityClass, newPriorityClass);
    return true;
}
#endif

//----------------------------------------------------------------------------------------------------------------------
#ifndef _WIN32
bool UsbDeviceBase::SetCurrentProcessRealtimePriority(ProcessPriorityRestoreInfo& priorityRestoreInfo)
{
    // Process priority is not a supported concept on a Linux-based OS
    return true;
}
#endif

//----------------------------------------------------------------------------------------------------------------------
#ifdef _WIN32
void UsbDeviceBase::RestoreCurrentProcessPriority(const ProcessPriorityRestoreInfo& priorityRestoreInfo)
{
    // Restore the original process priority class
    BOOL setPriorityClassReturn = SetPriorityClass(GetCurrentProcess(), priorityRestoreInfo.originalPriorityClass);
    if (setPriorityClassReturn == 0)
    {
        DWORD lastError = GetLastError();
        Log().Error("SetPriorityClass failed with error code {0}", lastError);
        return;
    }
}
#endif

//----------------------------------------------------------------------------------------------------------------------
#ifndef _WIN32
void UsbDeviceBase::RestoreCurrentProcessPriority(const ProcessPriorityRestoreInfo& priorityRestoreInfo)
{
    // Process priority is not a supported concept on a Linux-based OS
}
#endif

//----------------------------------------------------------------------------------------------------------------------
#ifdef _WIN32
bool UsbDeviceBase::SetCurrentThreadRealtimePriority(ThreadPriorityRestoreInfo& priorityRestoreInfo)
{
    // Retrieve the current thread priority
    HANDLE currentThreadHandle = GetCurrentThread();
    int originalThreadPriority = GetThreadPriority(currentThreadHandle);
    if (originalThreadPriority == THREAD_PRIORITY_ERROR_RETURN)
    {
        DWORD lastError = GetLastError();
        Log().Error("GetThreadPriority failed with error code {0}", lastError);
        return false;
    }

    // Attempt to increase thread priority to time critical
    int requestedPriority = THREAD_PRIORITY_TIME_CRITICAL;
    BOOL setThreadPriorityReturn = SetThreadPriority(currentThreadHandle, requestedPriority);
    if (setThreadPriorityReturn == 0)
    {
        DWORD lastError = GetLastError();
        Log().Error("SetThreadPriority failed with error code {0}", lastError);
        return false;
    }

    // Confirm the thread priority we ended up obtaining
    int newThreadPriority = GetThreadPriority(currentThreadHandle);
    priorityRestoreInfo.originalPriority = originalThreadPriority;
    Log().Info("SetCurrentThreadRealtimePriority: Requesting thread priority {0} gave us {1}", requestedPriority, newThreadPriority);
    return true;
}
#endif

//----------------------------------------------------------------------------------------------------------------------
#ifndef _WIN32
bool UsbDeviceBase::SetCurrentThreadRealtimePriority(ThreadPriorityRestoreInfo& priorityRestoreInfo)
{
    // Retrieve the current scheduling policy for the calling thread
    int oldSchedPolicy;
    sched_param oldSchedParam;
    pthread_getschedparam(pthread_self(), &oldSchedPolicy, &oldSchedParam);
    priorityRestoreInfo.oldSchedPolicy = oldSchedPolicy;
    priorityRestoreInfo.oldSchedParam = oldSchedParam;

    // Attempt to increase the thread scheduling policy to realtime
    int targetPolicy = SCHED_RR;
    int minSchedPriority = sched_get_priority_min(targetPolicy);
    int maxSchedPriority = sched_get_priority_max(targetPolicy);
    sched_param schedParams;
    if (minSchedPriority == -1 || maxSchedPriority == -1)
    {
        schedParams.sched_priority = 0;
    }
    else
    {
        // Put the priority about 3/4 of the way through its range
        schedParams.sched_priority = (minSchedPriority + (3 * maxSchedPriority)) / 4;
    }
    if (pthread_setschedparam(pthread_self(), targetPolicy, &schedParams) == 0)
    {
        Log().Info("SetCurrentThreadRealtimePriority: Thread priority set with policy SCHED_RR");
    }
    else
    {
        Log().Warning("SetCurrentThreadRealtimePriority: Unable to set thread priority");
    }
    return true;
}
#endif

//----------------------------------------------------------------------------------------------------------------------
#ifdef _WIN32
void UsbDeviceBase::RestoreCurrentThreadPriority(const ThreadPriorityRestoreInfo& priorityRestoreInfo)
{
    SetThreadPriority(GetCurrentThread(), priorityRestoreInfo.originalPriority);
}
#endif

//----------------------------------------------------------------------------------------------------------------------
#ifndef _WIN32
void UsbDeviceBase::RestoreCurrentThreadPriority(const ThreadPriorityRestoreInfo& priorityRestoreInfo)
{
    if (pthread_setschedparam(pthread_self(), priorityRestoreInfo.oldSchedPolicy, &priorityRestoreInfo.oldSchedParam) != 0)
    {
        Log().Warning("RestoreCurrentThreadPriority: Unable to restore original scheduling policy");
    }
}
#endif