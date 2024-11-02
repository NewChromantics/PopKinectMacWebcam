import Foundation
import CoreMediaIO
import Cocoa
import PopCameraDevice
import os.log




class SinkFrameSource : NSObject, CMIOExtensionStreamSource, FrameSource
{
	//	we own a stream which is a sink (doesn't get exposed to users)
	var sinkStream : CMIOExtensionStream?
	var SinkName = "Sink Name"
	var SinkUid : UUID = UUID()
	var Clients : [CMIOExtensionClient]	{	return sinkStream?.streamingClients ?? []	}

	let frameRate : Int32 = 60
	var initError : String?
	var running = true
	var sinkPusherStarted = false
	var format : StreamImageFormat
	
	
	init(device: CMIOExtensionDevice)
	{
		format = StreamImageFormat(width:600,height:500,pixelFormat: kCMPixelFormat_32BGRA)
		
		super.init()
		

		//	create sink source
		self.sinkStream = CMIOExtensionStream(localizedName: SinkName, streamID: SinkUid, direction: .sink, clockType: .hostTime, source: self)
		
		do
		{
			guard let sinkStream else
			{
				throw RuntimeError("Failed to allocate sink stream")
			}
			//	expose it to the device
			try device.addStream(sinkStream)

			//	listen for frames
			//	gr: this needs a client
			//startConsumingFrames()
		}
		catch let error
		{
			initError = error.localizedDescription
			os_log("Bootup error: \(error.localizedDescription)")
		}
	}
	
	func Free()
	{
		//	stop threads
		self.running = false
	}
	
	func ConsumeFrame(client:CMIOExtensionClient) async throws -> CMSampleBuffer
	{
		os_log("ConsumeFrame()")
		Logger.System.log("Consume from \(client.signingID!)")
		//	make nicer error
		do
		{
			guard let sinkStream else
			{
				throw RuntimeError("Missing sinkStream")
			}
			
			//throw RuntimeError( self.sinkPusherStarted  ? "ConsumeFrame" : "No sink-pusher-connected")

			let (Sample, SequenceNumber, Disconinuity, HasMoreSamples) = try await sinkStream.consumeSampleBuffer(from: client)
			os_log("Consumed buffer seq=\(SequenceNumber) more=\(HasMoreSamples)")
			//	notify it's been consumed
			let now = CMClockGetTime(CMClockGetHostTimeClock())
			let output = CMIOExtensionScheduledOutput(sequenceNumber: SequenceNumber, hostTimeInNanoseconds: UInt64(now.seconds * Double(NSEC_PER_SEC)))
			
			//	somewhere, having this causes the nil! exception?
			//	maybe this should ONLY be used in the callback version?
			//self.sinkStream!.notifyScheduledOutputChanged(output)
			
			os_log("sending dummy frame")
			throw RuntimeError( self.sinkPusherStarted  ? "ConsumedFrame(output)" : "No sink-pusher-connected")

			//first use of this immediately had nil! error
			return Sample
		}
		catch let Error
		{
			os_log("ConsumeSampleBuffer: \(Error.localizedDescription)")
			throw RuntimeError("ConsumeSampleBuffer: \(Error.localizedDescription)")
		}
	}
	
	func PopNewFrame() async throws -> Frame
	{
		while ( running )
		{
			if Clients.isEmpty
			{
				throw RuntimeError("Waiting for client")
			}
			
			var errors : [String] = []
			
			//	try and read from each client
			//	gr: does this block? which is okay - unless we have multiple clients...
			for client in Clients
			{
				do
				{
					//	sample is CMSampleBuffer
					//	cannot be null, so will this throw if no sample?
					let Sample = try await ConsumeFrame(client: client)
					let now = CMClockGetTime(CMClockGetHostTimeClock())
					/*
					 //self.lastTimingInfo.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock())
					 let output: CMIOExtensionScheduledOutput = CMIOExtensionScheduledOutput(sequenceNumber: seq, hostTimeInNanoseconds: UInt64(self.lastTimingInfo.presentationTimeStamp.seconds * Double(NSEC_PER_SEC)))
					 if self._streamingCounter > 0 {
					 self._streamSource.stream.send(sbuf!, discontinuity: [], hostTimeInNanoseconds: UInt64(sbuf!.presentationTimeStamp.seconds * Double(NSEC_PER_SEC)))
					 }
					 self._streamSink.stream.notifyScheduledOutputChanged(output)
					 */
					var frame = Frame(sample:Sample,time:now)
					return frame
				}
				catch let error
				{
					errors.append(error.localizedDescription)
				}
			}
			
			let errorsString = errors.joined(separator: ",")
			throw RuntimeError("Failed to get frame from x\(Clients.count) clients; \(errorsString)")
			
			//	no result (or no clients), pause
			let DelayMs = 1000 / Double(frameRate)
			try await Task.sleep(for:.milliseconds(DelayMs))
		}
		
		throw RuntimeError("No longer running")
	}
	
	/*
	func consumeBuffer(_ client: CMIOExtensionClient)
	{
		if sinkStarted == false {
			return
		}
	 //	gr: there is an async version of this
	 //https://developer.apple.com/documentation/coremediaio/cmioextensionstream/consumesamplebuffer(from:completionhandler:)/
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
	 */
	
	
	//	sink CMIOExtensionStreamSource funcs
	//	gr: getter?
	var formats: [CMIOExtensionStreamFormat]
	{
		let formats = [format].map
		{
			streamImageFormat in
			let Description = streamImageFormat.GetFormatDescripton()
			let MinFrameDurationSecs = CMTime(value: 1, timescale: Int32(30))
			let MaxFrameDurationSecs = CMTime(value: 1, timescale: Int32(60))
			let streamFormat = CMIOExtensionStreamFormat.init(formatDescription: Description, maxFrameDuration: MaxFrameDurationSecs, minFrameDuration: MinFrameDurationSecs, validFrameDurations: nil)
			return streamFormat
		}
		
		return formats
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
		if properties.contains(.streamFrameDuration) {
			let frameDuration = CMTime(value: 1, timescale: frameRate)
			streamProperties.frameDuration = frameDuration
		}
		if properties.contains(.streamSinkBufferQueueSize) {
			streamProperties.sinkBufferQueueSize = 1
		}
		if properties.contains(.streamSinkBuffersRequiredForStartup) {
			streamProperties.sinkBuffersRequiredForStartup = 1
		}
		return streamProperties
	}
		
	func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws
	{
	}
	
	//	gr: this doesn't get called
	func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool
	{
		//	gr: presumably this client app
		Logger.System.log("Client starting (to push?) to sink \(client.signingID!)")
		return true
	}
	
	func startStream() throws
	{
		//	start consuming loop if we havent
		os_log("Sink stream start")
		sinkPusherStarted = true
	}
	
	func stopStream() throws
	{
		//	if a client is pushing frames, why stop?
		os_log("Sink stream stop")
		sinkPusherStarted = false
	}
}






//	this is a stream which owns a Sink (which is also a stream) and displays whatever frames it receives
//	rather than having higher level code manage 2 sibling streams (sink & output)
class SinkConsumerStreamSource: NSObject, CMIOExtensionStreamSource
{
	var sinkFrameSource : SinkFrameSource
	var debugFrameSource : FrameSource	//	display text
	var displayText : String? = nil

	var stream : CMIOExtensionStream?
	let device: CMIOExtensionDevice	//	parent
	var supportedKinectFormats : [StreamImageFormat]

	//	we are/not supposed to be streaming (client, eg photobooth, connected)
	var streamInUse = false
	
	init(localizedStreamName: String, streamID: UUID, device: CMIOExtensionDevice, formats:[PopCameraDevice.StreamImageFormat])
	{
		sinkFrameSource = SinkFrameSource(device:device)
		debugFrameSource = DebugFrameSource(displayText: "Waiting for data in sink", clearColour: NSColor.purple.cgColor )
		
		let SomeFormat = StreamImageFormat(width: 123, height: 123, pixelFormat: kCMPixelFormat_32BGRA)
		self.supportedKinectFormats = [SomeFormat]
		
		//let KinectSource = /*self.kinectDevice*/device.source as! KinectDeviceSource
		//let label = "\(KinectSource.kinectDeviceMeta.Serial) \(localizedStreamName)"

		self.device = device
		
		super.init()
		
		self.stream = CMIOExtensionStream(localizedName: localizedStreamName, streamID: streamID, direction: .source, clockType: .hostTime, source: self)
		
		Task.detached
		{
			@MainActor in
			await self.FrameLoop()
		}
	}
	
	var formats: [CMIOExtensionStreamFormat]
	{
		//	supported formats
		let formats = supportedKinectFormats.map
		{
			streamImageFormat in
			let Description = streamImageFormat.GetFormatDescripton()
			let MinFrameDurationSecs = CMTime(value: 1, timescale: Int32(30))
			let MaxFrameDurationSecs = CMTime(value: 1, timescale: Int32(60))
			let streamFormat = CMIOExtensionStreamFormat.init(formatDescription: Description, maxFrameDuration: MaxFrameDurationSecs, minFrameDuration: MinFrameDurationSecs, validFrameDurations: nil)
			return streamFormat
		}
		return formats
	}
	/*
	var activeFormatIndex: Int = 0 {
		
		didSet {
			if activeFormatIndex >= 1 {
				os_log(.error, "Invalid index")
			}
		}
	}
	*/

	var availableProperties: Set<CMIOExtensionProperty>
	{
		//	add sink name here
		return []//[.streamFrameDuration]
	}
	
	
	//	virtual
	func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties
	{
		//	os expects data for all properties
		let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
		return streamProperties
	}
	
	//	virtual
	func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws
	{
	}
	
	//	virtual
	func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool
	{
		//	the client here is photobooth, not SinkPusher...
		return true
	}
	
	func startStream() throws
	{
		self.streamInUse = true
	}
	
	func stopStream() throws
	{
		self.streamInUse = false
	}
	
	func ClearError()
	{
		displayText = nil
	}
	
	func OnError(_ error:String?)
	{
		displayText = error
	}
	
	
	func DisplayFrameFrom(frameSource:FrameSource) async
	{
		do
		{
			let frame = try await frameSource.PopNewFrame()
			
			guard let stream else
			{
				throw RuntimeError("Stream is null")
			}
			
			try stream.send( frame.sampleBuffer, discontinuity: [], hostTimeInNanoseconds: frame.timeNanos )
			
			//	remove error
			self.ClearError()
		}
		catch let error
		{
			//	display an error
			self.OnError("\(error.localizedDescription)")
		}
	}
	
	func ConsumeFrameDirectly(client:CMIOExtensionClient) async throws
	{
		guard let sinkStream = sinkFrameSource.sinkStream else
		{
			throw RuntimeError("Missing sink strem")
		}
		
		Logger.System.log("Consume from \(client.signingID!)")
		let (Sample, SequenceNumber, Disconinuity, HasMoreSamples) = try await sinkStream.consumeSampleBuffer(from: client)
		
		let now = CMClockGetTime(CMClockGetHostTimeClock())
		let nowNanos = UInt64(now.seconds * Double(NSEC_PER_SEC))
		
		os_log("Consumed buffer seq=\(SequenceNumber) more=\(HasMoreSamples) send()...")
		try stream!.send( Sample, discontinuity: [], hostTimeInNanoseconds: nowNanos )
		
		os_log("notify buffer seq=\(SequenceNumber)")
		
		//	notify it's been consumed
		let output = CMIOExtensionScheduledOutput(sequenceNumber: SequenceNumber, hostTimeInNanoseconds: nowNanos)
		sinkStream.notifyScheduledOutputChanged(output)
	}
	
	func FrameLoop() async
	{
		while ( true )
		{
			/*	gr allow consume() call to error with its specific error
			if !streamInUse
			{
				//	todo: wait on a wake-up semaphore
				try! await Task.sleep(for: .seconds(1))
				continue
			}
			 */

			//	if we have some display text, display a frame of that
			//	then do normal frame output which may clear this text (if its an error)
			if let displayText
			{
				if let debug = debugFrameSource as? DebugFrameSource
				{
					debug.displayText = displayText
					await DisplayFrameFrom(frameSource:debug)
				}
				
				let DelayMs = 1000 / Double(30)
				do
				{
					try await Task.sleep(for:.milliseconds(DelayMs))
				}
				catch let Error
				{
					Logger.System.log("\(Error.localizedDescription)")
				}
			}
			
			if ( sinkFrameSource.Clients.isEmpty )
			{
				OnError("Waiting for client...")
			}
			
			//await DisplayFrameFrom(frameSource:sinkFrameSource)
			for client in sinkFrameSource.Clients
			{
				do
				{
					try await ConsumeFrameDirectly(client: client)
					ClearError()
				}
				catch let Error
				{
					os_log("Consume directly error: \(Error.localizedDescription)")
				}
			}
		}
		
	}
	
}
