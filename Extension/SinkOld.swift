import Foundation
import CoreMediaIO
import IOKit.audio
import os.log
import Cocoa


public let SinkPropertyKey = "sink"
let SinkProperty : CMIOExtensionProperty = CMIOExtensionProperty(rawValue: "4cc_\(SinkPropertyKey)_glob_0000")



let kFrameRate: Int = 60
let cameraName = "PopShaderCamera Camera Name"
let fixedCamWidth: Int32 = 1280
let fixedCamHeight: Int32 = 720



class cameraDeviceSource: NSObject, CMIOExtensionDeviceSource
{
	var debugFrameSource = DebugFrameSource(displayText: "Something", clearColour: NSColor.magenta.cgColor)
	
	private(set) var device: CMIOExtensionDevice!
	
	public var _streamSource: cameraStreamSource!
	public var _streamSink: cameraStreamSink!
	private var _streamingCounter: UInt32 = 0
	private var _streamingSinkCounter: UInt32 = 0
	private var _videoDescription: CMFormatDescription!

	var consumeSinkTimer: DispatchSourceTimer?
	let consumeSinkTimerQueue = DispatchQueue(label: "consumeSinkTimerQueue", qos: .userInteractive, attributes: [], autoreleaseFrequency: .workItem, target: .global(qos: .userInteractive))
	
		
	var lastError : String? = nil
	
	func myStreamingCounter() -> String {
		return "SinkConsumerCounter=\(_streamingCounter)"
	}
	
	init(localizedName: String) {
		
		
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
		_streamSource = cameraStreamSource(localizedName: "PopShaderCamera.Video", streamID: videoID, streamFormat: videoStreamFormat, device: device)
		let videoSinkID = UUID()
		_streamSink = cameraStreamSink(localizedName: "PopShaderCamera.Video.Sink", streamID: videoSinkID, streamFormat: videoStreamFormat, device: device)
		do {
			try device.addStream(_streamSource.stream)
			try device.addStream(_streamSink.stream)
		} catch let error {
			fatalError("Failed to add stream: \(error.localizedDescription)")
		}
	}
	
	var availableProperties: Set<CMIOExtensionProperty> {
		
		return [.deviceTransportType, .deviceModel]
	}
	
	func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
		
		let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
		if properties.contains(.deviceTransportType) {
			deviceProperties.transportType = kIOAudioDeviceTransportTypeVirtual
		}
		if properties.contains(.deviceModel) {
			//deviceProperties.setPropertyState(CMIOExtensionPropertyState(value: "toto" as NSString), forProperty: .deviceModel)
			deviceProperties.model = "PopShaderCamera Model"
		}
		
		return deviceProperties
	}
	
	func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {
		
		
		// Handle settable properties here.
	}
	
	
	func UpdateFrame()
	{
		//	if we're not using consume buffer, show our debug
		//if self.sinkStarted
		if true
		{
			for client in self._streamSink.stream.streamingClients
			{
				do
				{
					try self.consumeOneBuffer(client)
					return
				}
				catch let err
				{
					self.lastError = err.localizedDescription
				}
			}
		}
		
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
			self.UpdateFrame()
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
	
	var sinkStarted = false
	var lastTimingInfo = CMSampleTimingInfo()
	
	func consumeOneBuffer(_ client: CMIOExtensionClient) throws
	{
		var SomeError : String? = nil
		self._streamSink.stream.consumeSampleBuffer(from: client)
		{
			sbuf, seq, discontinuity, hasMoreSampleBuffers, err in
			if let sbuf
			{
				self.lastTimingInfo.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock())
				let output: CMIOExtensionScheduledOutput = CMIOExtensionScheduledOutput(sequenceNumber: seq, hostTimeInNanoseconds: UInt64(self.lastTimingInfo.presentationTimeStamp.seconds * Double(NSEC_PER_SEC)))
				if self._streamingCounter > 0
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
	
	func consumeBuffer(_ client: CMIOExtensionClient)
	{
		if sinkStarted == false {
			return
		}
		self._streamSink.stream.consumeSampleBuffer(from: client)
		{
			sbuf, seq, discontinuity, hasMoreSampleBuffers, err in
			if let sbuf
			{
				self.lastTimingInfo.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock())
				let output: CMIOExtensionScheduledOutput = CMIOExtensionScheduledOutput(sequenceNumber: seq, hostTimeInNanoseconds: UInt64(self.lastTimingInfo.presentationTimeStamp.seconds * Double(NSEC_PER_SEC)))
				if self._streamingCounter > 0
				{
					self._streamSource.stream.send(sbuf, discontinuity: [], hostTimeInNanoseconds: UInt64(sbuf.presentationTimeStamp.seconds * Double(NSEC_PER_SEC)))
				}
				self._streamSink.stream.notifyScheduledOutputChanged(output)
			}
			else
			{
				self.lastError = err?.localizedDescription ?? "ConsumeBuffer missing sample"
			}

			self.consumeBuffer(client)
		}
	}
	
	func startStreamingSink(client: CMIOExtensionClient) {
		
		_streamingSinkCounter += 1
		self.sinkStarted = true
		//consumeBuffer(client)
	}
	
	func stopStreamingSink() {
		self.sinkStarted = false
		if _streamingSinkCounter > 1 {
			_streamingSinkCounter -= 1
		}
		else {
			_streamingSinkCounter = 0
		}
	}}



class cameraStreamSource: NSObject, CMIOExtensionStreamSource {
	
	private(set) var stream: CMIOExtensionStream!
	
	let device: CMIOExtensionDevice
	//public var nConnectedClients = 0
	private let _streamFormat: CMIOExtensionStreamFormat
	var count = 0

	
	init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
		
		self.device = device
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
		guard let deviceSource = device.source as? cameraDeviceSource else
		{
			fatalError("Unexpected source type \(String(describing: device.source))")
		}
		
		try deviceSource.startStreaming()
	}
	
	func stopStream() throws
	{
		guard let deviceSource = device.source as? cameraDeviceSource else
		{
			fatalError("Unexpected source type \(String(describing: device.source))")
		}

		deviceSource.stopStreaming()
	}
}

class cameraStreamSink: NSObject, CMIOExtensionStreamSource {
	
	private(set) var stream: CMIOExtensionStream!
	let device: CMIOExtensionDevice
	private let _streamFormat: CMIOExtensionStreamFormat
	var client: CMIOExtensionClient?
	
	init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
		
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
			SinkProperty,
			.streamFrameDuration,
			.streamSinkBufferQueueSize,
			.streamSinkBuffersRequiredForStartup,
			.streamSinkBufferUnderrunCount,
			.streamSinkEndOfData
		]
	}
	
	func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
		let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
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
		
		streamProperties.setPropertyState( CMIOExtensionPropertyState(value: "Hello" as NSString), forProperty: SinkProperty )
		
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
	
	func startStream() throws {
		
		guard let deviceSource = device.source as? cameraDeviceSource else {
			fatalError("Unexpected source type \(String(describing: device.source))")
		}
		if let client = client {
			deviceSource.startStreamingSink(client: client)
		}
	}
	
	func stopStream() throws {
		
		guard let deviceSource = device.source as? cameraDeviceSource else {
			fatalError("Unexpected source type \(String(describing: device.source))")
		}
		deviceSource.stopStreamingSink()
	}
}


