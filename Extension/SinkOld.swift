import Foundation
import CoreMediaIO
import IOKit.audio
import os.log
import Cocoa





let kFrameRate: Int = 60
let fixedCamWidth: Int32 = 1280
let fixedCamHeight: Int32 = 720



class cameraDeviceSource: NSObject, CMIOExtensionDeviceSource
{
	var debugFrameSource = DebugFrameSource(displayText: "Something", clearColour: NSColor.magenta.cgColor)
	
	var device: CMIOExtensionDevice!
	
	var _streamSource: cameraStreamSource!
	var _videoDescription: CMFormatDescription!
	var _streamSink: cameraStreamSink!
	var _streamingCounter: UInt32 = 0
	var isStreamBeingWatched : Bool	{	return _streamingCounter > 0	}
	
	var consumeSinkTimer: DispatchSourceTimer?
	let consumeSinkTimerQueue = DispatchQueue(label: "consumeSinkTimerQueue", qos: .userInteractive, attributes: [], autoreleaseFrequency: .workItem, target: .global(qos: .userInteractive))
	
	var lastError : String? = nil
	
	
	init(localizedName: String)
	{
		let SinkPropertyKey = "sink"
		
		super.init()
		let deviceID = UUID()
		self.device = CMIOExtensionDevice(localizedName: localizedName, deviceID: deviceID, legacyDeviceID: deviceID.uuidString, source: self)
		
		let dims = CMVideoDimensions(width: fixedCamWidth, height: fixedCamHeight)
		CMVideoFormatDescriptionCreate(
			allocator: kCFAllocatorDefault,
			codecType: kCVPixelFormatType_32BGRA,
			width: dims.width, height: dims.height, extensions: nil, formatDescriptionOut: &_videoDescription)
		
		let videoStreamFormat = CMIOExtensionStreamFormat.init(formatDescription: _videoDescription, maxFrameDuration: CMTime(value: 1, timescale: Int32(kFrameRate)), minFrameDuration: CMTime(value: 1, timescale: Int32(kFrameRate)), validFrameDurations: nil)
		
		let videoID = UUID()
		_streamSource = cameraStreamSource(localizedName: "OutputStream", streamID: videoID, streamFormat: videoStreamFormat, device: device)
		let videoSinkID = UUID()
		_streamSink = cameraStreamSink(localizedName: "Sink", streamID: videoSinkID, streamFormat: videoStreamFormat, device: device, sinkPropertyKey: SinkPropertyKey)
		
		do
		{
			try device.addStream(_streamSource.stream)
			try device.addStream(_streamSink.stream)
		}
		catch let error
		{
			fatalError("Failed to add stream: \(error.localizedDescription)")
		}
	}
	
	var availableProperties: Set<CMIOExtensionProperty> {
		
		return [/*.deviceTransportType, .deviceModel*/]
	}
	
	func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
		
		let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
		/*
		if properties.contains(.deviceTransportType) {
			deviceProperties.transportType = kIOAudioDeviceTransportTypeVirtual
		}
		if properties.contains(.deviceModel) {
			//deviceProperties.setPropertyState(CMIOExtensionPropertyState(value: "toto" as NSString), forProperty: .deviceModel)
			deviceProperties.model = "PopShaderCamera Model"
		}
		*/
		return deviceProperties
	}
	
	func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws
	{
		// Handle settable properties here.
	}
	
	func UpdateFrameAsync() async
	{
		//	if there are clients attached to the sink, consume from them
		for client in self._streamSink.stream.streamingClients
		{
			do
			{
				//	this async version will crash with a nil unwrap - but not sure why/where
				//try await self.consumeOneBufferAsync(client)
				try self.consumeOneBuffer(client)
				return
			}
			catch let err
			{
				self.lastError = err.localizedDescription
			}
		}
		
		//	haven't consumed from buffer, push a debug frame
		do
		{
			self.debugFrameSource.displayText = self.lastError ?? "Waiting for something"
			let Frame = try self.debugFrameSource.PopNewFrameSync()
			
			try self._streamSource.stream.send( Frame.sampleBuffer, discontinuity: [], hostTimeInNanoseconds: Frame.timeNanos )
			
			//	remove error
			self.lastError = nil
		}
		catch let error
		{
			//	display an error
			self.lastError = "\(error.localizedDescription)"
		}
	}
	
	
	
	func startStreaming() throws
	{
		_streamingCounter += 1
		
		//	gr: could we just always have the timer running?
		//		just dont push if nothing recieving?
		if ( consumeSinkTimer == nil )
		{
			consumeSinkTimer = DispatchSource.makeTimerSource(flags: .strict, queue: consumeSinkTimerQueue)
		}
		guard let consumeSinkTimer else
		{
			throw RuntimeError("Failed to start timer")
		}
		
		consumeSinkTimer.schedule(deadline: .now(), repeating: 1.0/Double(kFrameRate), leeway: .seconds(0))
		consumeSinkTimer.setEventHandler
		{
			Task
			{
				await self.UpdateFrameAsync()
			}
		}
		
		consumeSinkTimer.setCancelHandler
		{
		}
		
		consumeSinkTimer.resume()
	}
	
	func stopStreaming() {
		if _streamingCounter > 1 {
			_streamingCounter -= 1
		}
		else
		{
			_streamingCounter = 0
			if ( consumeSinkTimer != nil )
			{
				consumeSinkTimer!.cancel()
				consumeSinkTimer = nil
			}
		}
	}
	
	func consumeOneBufferAsync(_ client: CMIOExtensionClient) async throws
	{
		do
		{
			let (Sample,SequenceNumber,Discontinuity,HasMoreSamples) = try await self._streamSink.stream.consumeSampleBuffer(from: client)
			let Now = CMClockGetTime(CMClockGetHostTimeClock())
			let NowNanos = UInt64(Now.seconds * Double(NSEC_PER_SEC))
			
			let output: CMIOExtensionScheduledOutput = CMIOExtensionScheduledOutput(sequenceNumber: SequenceNumber, hostTimeInNanoseconds:NowNanos)
			if self.isStreamBeingWatched
			{
				self._streamSource.stream.send(Sample, discontinuity: [], hostTimeInNanoseconds: UInt64(Sample.presentationTimeStamp.seconds * Double(NSEC_PER_SEC)))
			}
			self._streamSink.stream.notifyScheduledOutputChanged(output)
		}
		catch let Error
		{
			let error = Error.localizedDescription
			throw RuntimeError("consumeOneBufferAsync Error \(error)")
		}
	}
	
	func consumeOneBuffer(_ client: CMIOExtensionClient) throws
	{
		var SomeError : String? = nil
		self._streamSink.stream.consumeSampleBuffer(from: client)
		{
			sbuf, seq, discontinuity, hasMoreSampleBuffers, err in
			if let sbuf
			{
				let Now = CMClockGetTime(CMClockGetHostTimeClock())
				let NowNanos = UInt64(Now.seconds * Double(NSEC_PER_SEC))
				
				let output: CMIOExtensionScheduledOutput = CMIOExtensionScheduledOutput(sequenceNumber: seq, hostTimeInNanoseconds:NowNanos)
				if self.isStreamBeingWatched
				{
					self._streamSource.stream.send(sbuf, discontinuity: [], hostTimeInNanoseconds: UInt64(sbuf.presentationTimeStamp.seconds * Double(NSEC_PER_SEC)))
				}
				self._streamSink.stream.notifyScheduledOutputChanged(output)
			}
			else
			{
				let error = err?.localizedDescription ?? "ConsumeBuffer missing sample"
				//throw RuntimeError("ConsumeBuffer Error \(error)")
				SomeError = error
			}
		}
		if let SomeError
		{
			throw RuntimeError(SomeError)
		}
	}
	
}



class cameraStreamSource : NSObject, CMIOExtensionStreamSource
{
	private(set) var stream: CMIOExtensionStream!
	
	let parent : CMIOExtensionDevice	//	parent
	private let _streamFormat: CMIOExtensionStreamFormat
	
	
	init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
		
		self.parent = device
		self._streamFormat = streamFormat
		super.init()
		self.stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: .source, clockType: .hostTime, source: self)
	}
	
	var formats: [CMIOExtensionStreamFormat] {
		
		return [_streamFormat]
	}
	
	
	var availableProperties: Set<CMIOExtensionProperty> {
		
		return [.streamFrameDuration]
	}
	
	
	//	virtual
	func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties
	{
		let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
		if properties.contains(.streamFrameDuration) {
			let frameDuration = CMTime(value: 1, timescale: Int32(kFrameRate))
			streamProperties.frameDuration = frameDuration
		}
		return streamProperties
	}
	
	//	virtual
	func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws
	{
	}
	
	func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool
	{
		// An opportunity to inspect the client info and decide if it should be allowed to start the stream.
		return true
	}
	
	func startStream() throws
	{
		guard let deviceSource = parent.source as? cameraDeviceSource else
		{
			fatalError("Unexpected source type \(String(describing: parent.source))")
		}
		
		try deviceSource.startStreaming()
	}
	
	func stopStream() throws
	{
		guard let deviceSource = parent.source as? cameraDeviceSource else
		{
			fatalError("Unexpected source type \(String(describing: parent.source))")
		}

		deviceSource.stopStreaming()
	}
}

class cameraStreamSink: NSObject, CMIOExtensionStreamSource {
	
	private(set) var stream: CMIOExtensionStream!
	let device: CMIOExtensionDevice
	private let _streamFormat: CMIOExtensionStreamFormat
	var client: CMIOExtensionClient?
	
	var sinkPropertyKey : String
	let sinkProperty : CMIOExtensionProperty
	var sinkPropertyValue = "Hello"
	
	init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice, sinkPropertyKey:String)
	{
		self.sinkPropertyKey = sinkPropertyKey
		self.sinkProperty = CMIOExtensionProperty(rawValue: "4cc_\(sinkPropertyKey)_glob_0000")

		self.device = device
		self._streamFormat = streamFormat
		
		super.init()
		
		self.stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: .sink, clockType: .hostTime, source: self)
	}
	
	var formats: [CMIOExtensionStreamFormat] {
		
		return [_streamFormat]
	}
	
	var availableProperties: Set<CMIOExtensionProperty>
	{
		return [
			sinkProperty/*,
			.streamFrameDuration,
			.streamSinkBufferQueueSize,
			.streamSinkBuffersRequiredForStartup,
			.streamSinkBufferUnderrunCount,
			.streamSinkEndOfData
						 */
		]
	}
	
	func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties
	{
		let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
		/*
		if properties.contains(.streamFrameDuration) {
			let frameDuration = CMTime(value: 1, timescale: Int32(kFrameRate))
			streamProperties.frameDuration = frameDuration
		}
		if properties.contains(.streamSinkBufferQueueSize) {
			streamProperties.sinkBufferQueueSize = 1
		}
		if properties.contains(.streamSinkBuffersRequiredForStartup) {
			streamProperties.sinkBuffersRequiredForStartup = 1
		}
		*/
		streamProperties.setPropertyState( CMIOExtensionPropertyState(value: sinkPropertyValue as NSString), forProperty: sinkProperty )
		
		return streamProperties
	}
	
	func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws
	{
	}
	
	func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
		
		// An opportunity to inspect the client info and decide if it should be allowed to start the stream.
		self.client = client
		return true
	}
	
	func startStream() throws
	{
		//	something now wants to push to the sink
	}
	
	func stopStream() throws
	{
	}
}


