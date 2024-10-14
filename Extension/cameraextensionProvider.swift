import Foundation
import CoreMediaIO
import IOKit.audio
import os.log
import Cocoa

let textColor = NSColor.white
let fontSize = 24.0
let textFont = NSFont.systemFont(ofSize: fontSize)
let CMIOExtensionPropertyCustomPropertyData_just: CMIOExtensionProperty = CMIOExtensionProperty(rawValue: "4cc_just_glob_0000")
let kWhiteStripeHeight: Int = 10


class cameraDeviceSource: NSObject, CMIOExtensionDeviceSource
{
	private(set) var device: CMIOExtensionDevice!
	
	public var _streamSource: cameraStreamSource!
	public var _streamSink: cameraStreamSink!
	private var _streamingCounter: UInt32 = 0
	private var _streamingSinkCounter: UInt32 = 0
	
	var frameSource : FrameSource
	
	
	func myStreamingCounter() -> String {
		return "SinkConsumerCounter=\(_streamingCounter)"
	}
	
	init(localizedName: String) {
		
		frameSource = DebugFrameSource()
		
		super.init()
		let deviceID = UUID()
		self.device = CMIOExtensionDevice(localizedName: localizedName, deviceID: deviceID, legacyDeviceID: deviceID.uuidString, source: self)
		
		
		let videoStreamFormat = CMIOExtensionStreamFormat.init(formatDescription: frameSource.videoFormat, maxFrameDuration: frameSource.maxFrameDuration, minFrameDuration: frameSource.maxFrameDuration, validFrameDurations: nil)
		
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
	
	
	
	
	func FrameLoop() async
	{
		while ( true )
		{
			do
			{
				let frame = try await frameSource.PopNewFrame()

				var sbuf: CMSampleBuffer!
				var timingInfo = CMSampleTimingInfo()
				timingInfo.presentationTimeStamp = frame.time
				let err = CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: frame.pixels, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: frame.format, sampleTiming: &timingInfo, sampleBufferOut: &sbuf)
				if err != 0
				{
					throw RuntimeError("Error creating sample buffer \(err)")
				}
				self._streamSource.stream.send(sbuf, discontinuity: [], hostTimeInNanoseconds: UInt64(timingInfo.presentationTimeStamp.seconds * Double(NSEC_PER_SEC)))
				
				//	remove error
				self.ClearError()
			}
			catch let error
			{
				//	display an error
				self.OnError("\(error.localizedDescription)")
			}
			
		}
		
	}
	
	
	func ClearError()
	{
		OnError(nil)
	}
	
	func OnError(_ error:String?)
	{
		if let source = self.frameSource as? DebugFrameSource
		{
			source.warningText = error
		}
	}
	
	func startStreaming()
	{
		_streamingCounter += 1
		let FrameLoopTask = Task
		{
			await FrameLoop()
		}
		
	}
	
	func stopStreaming() {
		if _streamingCounter > 1 {
			_streamingCounter -= 1
		}
		else {
			_streamingCounter = 0
		}
	}
	
	var sinkStarted = false
	var lastTimingInfo = CMSampleTimingInfo()
	
	
	
	func consumeBuffer(_ client: CMIOExtensionClient)
	{
		if sinkStarted == false {
			return
		}
		self._streamSink.stream.consumeSampleBuffer(from: client) { sbuf, seq, discontinuity, hasMoreSampleBuffers, err in
			if sbuf != nil {
				self.lastTimingInfo.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock())
				let output: CMIOExtensionScheduledOutput = CMIOExtensionScheduledOutput(sequenceNumber: seq, hostTimeInNanoseconds: UInt64(self.lastTimingInfo.presentationTimeStamp.seconds * Double(NSEC_PER_SEC)))
				if self._streamingCounter > 0 {
					self._streamSource.stream.send(sbuf!, discontinuity: [], hostTimeInNanoseconds: UInt64(sbuf!.presentationTimeStamp.seconds * Double(NSEC_PER_SEC)))
				}
				self._streamSink.stream.notifyScheduledOutputChanged(output)
			}
			self.consumeBuffer(client)
		}
	}
	
	func startStreamingSink(client: CMIOExtensionClient) {
		
		_streamingSinkCounter += 1
		self.sinkStarted = true
		consumeBuffer(client)
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
	
	init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
		
		self.device = device
		self._streamFormat = streamFormat
		super.init()
		self.stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: .source, clockType: .hostTime, source: self)
	}
	
	var formats: [CMIOExtensionStreamFormat] {
		
		return [_streamFormat]
	}
	
	var activeFormatIndex: Int = 0 {
		
		didSet {
			if activeFormatIndex >= 1 {
				os_log(.error, "Invalid index")
			}
		}
	}
	
	var availableProperties: Set<CMIOExtensionProperty> {
		
		return [.streamActiveFormatIndex, .streamFrameDuration, CMIOExtensionPropertyCustomPropertyData_just]
	}
	
	public var just: String = "toto"
	public var rust: String = "0"
	var count = 0
	
	//	virtual
	func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties
	{
		let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
		if properties.contains(.streamActiveFormatIndex) {
			streamProperties.activeFormatIndex = 0
		}
		if properties.contains(.streamFrameDuration)
		{
			//	todo gr
			//let frameDuration = CMTime(value: 1, timescale: Int32(kFrameRate))
			//streamProperties.frameDuration = frameDuration
		}
		if properties.contains(CMIOExtensionPropertyCustomPropertyData_just)
		{
			streamProperties.setPropertyState(CMIOExtensionPropertyState(value: self.just as NSString), forProperty: CMIOExtensionPropertyCustomPropertyData_just)
		}
		return streamProperties
	}
	
	//	virtual
	func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws
	{
		
		if let activeFormatIndex = streamProperties.activeFormatIndex {
			self.activeFormatIndex = activeFormatIndex
		}
		
		if let state = streamProperties.propertiesDictionary[CMIOExtensionPropertyCustomPropertyData_just] {
			if let newValue = state.value as? String {
				self.just = newValue
				if let deviceSource = device.source as? cameraDeviceSource {
					self.just = deviceSource.myStreamingCounter()
				}
			}
		}
	}
	
	func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool
	{
		// An opportunity to inspect the client info and decide if it should be allowed to start the stream.
		return true
	}
	
	func startStream() throws
	{
		
		guard let deviceSource = device.source as? cameraDeviceSource else {
			fatalError("Unexpected source type \(String(describing: device.source))")
		}
		self.rust = "1"
		deviceSource.startStreaming()
	}
	
	func stopStream() throws {
		
		guard let deviceSource = device.source as? cameraDeviceSource else {
			fatalError("Unexpected source type \(String(describing: device.source))")
		}
		self.rust = "0"
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
	
	var activeFormatIndex: Int = 0 {
		
		didSet {
			if activeFormatIndex >= 1 {
				os_log(.error, "Invalid index")
			}
		}
	}
	
	var availableProperties: Set<CMIOExtensionProperty>
	{
		return [
			.streamActiveFormatIndex,
			.streamFrameDuration,
			.streamSinkBufferQueueSize,
			.streamSinkBuffersRequiredForStartup,
			.streamSinkBufferUnderrunCount,
			.streamSinkEndOfData
		]
	}
	
	func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
		let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
		if properties.contains(.streamActiveFormatIndex) {
			streamProperties.activeFormatIndex = 0
		}
		if properties.contains(.streamFrameDuration)
		{
			//	gr: todo
			//let frameDuration = CMTime(value: 1, timescale: Int32(kFrameRate))
			//streamProperties.frameDuration = frameDuration
		}
		if properties.contains(.streamSinkBufferQueueSize) {
			streamProperties.sinkBufferQueueSize = 1
		}
		if properties.contains(.streamSinkBuffersRequiredForStartup) {
			streamProperties.sinkBuffersRequiredForStartup = 1
		}
		return streamProperties
	}
	
	func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
		
		if let activeFormatIndex = streamProperties.activeFormatIndex {
			self.activeFormatIndex = activeFormatIndex
		}
		
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

// MARK: -

class cameraProviderSource: NSObject, CMIOExtensionProviderSource {
	
	private(set) var provider: CMIOExtensionProvider!
	
	private var deviceSource: cameraDeviceSource!
	
	init(clientQueue: DispatchQueue?) {
		super.init()
		provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
		deviceSource = cameraDeviceSource(localizedName: cameraName)
		
		do {
			try provider.addDevice(deviceSource.device)
		} catch let error {
			fatalError("Failed to add device: \(error.localizedDescription)")
		}
	}
	
	func connect(to client: CMIOExtensionClient) throws {
		
	}
	
	func disconnect(from client: CMIOExtensionClient) {
		
	}
	
	var availableProperties: Set<CMIOExtensionProperty> {
		
		// See full list of CMIOExtensionProperty choices in CMIOExtensionProperties.h
		return [.providerManufacturer]
	}
	
	func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
		
		let providerProperties = CMIOExtensionProviderProperties(dictionary: [:])
		if properties.contains(.providerManufacturer) {
			providerProperties.manufacturer = "New Chromantics"
		}
		return providerProperties
	}
	
	func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {
		// Handle settable properties here.
	}
}

