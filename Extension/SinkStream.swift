import Foundation
import CoreMediaIO
import Cocoa
import PopCameraDevice




class SinkFrameSource : NSObject, CMIOExtensionStreamSource, FrameSource
{
	//	we own a stream which is a sink (doesn't get exposed to users)
	var sinkStream : CMIOExtensionStream!
	var SinkName = "Sink Name"
	var SinkUid : UUID = UUID()
	var Clients : [CMIOExtensionClient] = []

	var bufferPool: CVPixelBufferPool!
	var bufferAuxAttributes: NSDictionary!
	let width : Int32 = 640
	let height : Int32 = 480
	let frameRate = 60
	let pixelFormat = kCVPixelFormatType_32BGRA
	var videoFormat : CMFormatDescription!
	var maxFrameDuration : CMTime
	{
		CMTime(value: 1, timescale: Int32(60))
	}
	
	//	externally set text
	var warningText : String?
	
	var initError : String?

	var running = true
	
	init(device: CMIOExtensionDevice)
	{
		super.init()

		//	create sink source
		self.sinkStream = CMIOExtensionStream(localizedName: SinkName, streamID: SinkUid, direction: .sink, clockType: .hostTime, source: self)
		
		do
		{
			//	expose it to the device
			try device.addStream(sinkStream)

			//	listen for frames
			//	gr: this needs a client
			//startConsumingFrames()
		}
		catch let error
		{
			initError = error.localizedDescription
		}
	}
	
	func Free()
	{
		//	stop threads
		self.running = false
	}
	
	func ConsumeFrame(client:CMIOExtensionClient) async throws -> CMSampleBuffer
	{
		//	make nicer error
		do
		{
			let (Sample, SequenceNumber, Disconinuity, HasMoreSamples) = try await sinkStream.consumeSampleBuffer(from: client)
			return Sample
		}
		catch let Error
		{
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
			
			//	try and read from each client
			//	gr: does this block? which is okay - unless we have multiple clients...
			for client in Clients
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
		return []
	}
	
	var availableProperties: Set<CMIOExtensionProperty>
	{
		return []//[.streamFrameDuration]
	}

	func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties
	{
		//	os expects data for all properties
		let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
		return streamProperties
	}
	
	func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws
	{
	}
	
	//	gr: this doesn't get called
	func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool
	{
		//	gr: presumably this client app
		print("Client starting (to push?) to sink \(client.signingID)")
		Clients.append(client)
		return true
	}
	
	func startStream() throws
	{
		//	start consuming loop if we havent
		print("Sink stream start")
	}
	
	func stopStream() throws
	{
		//	if a client is pushing frames, why stop?
		print("Sink stream stop")
	}
}






//	this is a stream which owns a Sink (which is also a stream) and displays whatever frames it receives
//	rather than having higher level code manage 2 sibling streams (sink & output)
class SinkConsumerStreamSource: NSObject, CMIOExtensionStreamSource
{
	var sinkFrameSource : SinkFrameSource
	var debugFrameSource : FrameSource	//	display text
	var displayText : String? = nil

	var stream : CMIOExtensionStream!
	let device: CMIOExtensionDevice	//	parent
	var supportedKinectFormats : [StreamImageFormat]

	//	we are/not supposed to be streaming
	var sinkPusherStarted = false
	
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
		
		Task
		{
			await FrameLoop()
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
		self.sinkPusherStarted = true
	}
	
	func stopStream() throws
	{
		self.sinkPusherStarted = false
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
			
			try self.stream.send( frame.sampleBuffer, discontinuity: [], hostTimeInNanoseconds: frame.timeNanos )
			
			//	remove error
			self.ClearError()
		}
		catch let error
		{
			//	display an error
			self.OnError("\(error.localizedDescription)")
		}
	}
	
	
	func FrameLoop() async
	{
		while ( true )
		{
			/*	gr allow consume() call to error with its specific error
			if !sinkPusherStarted
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
				try! await Task.sleep(for:.milliseconds(DelayMs))
			}
			
			await DisplayFrameFrom(frameSource:sinkFrameSource)
			
		}
		
	}
	
}
