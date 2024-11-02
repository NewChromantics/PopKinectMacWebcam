import Foundation
import CoreMediaIO
import Cocoa



class SinkDevice : NSObject, CMIOExtensionDeviceSource
{
	var debugFrameSource = DebugFrameSource(displayText: "Something", clearColour: NSColor.magenta.cgColor)
	
	var device: CMIOExtensionDevice!
	
	var outputStream : SinkOutputStream!
	var isStreamBeingWatched : Bool	{	return outputStream.isBeingObserved	}
	var sink : SinkStream!
	
	var _videoDescription: CMFormatDescription!
	var consumeSinkTimer: DispatchSourceTimer?
	let consumeSinkTimerQueue = DispatchQueue(label: "consumeSinkTimerQueue", qos: .userInteractive, attributes: [], autoreleaseFrequency: .workItem, target: .global(qos: .userInteractive))
	
	var lastError : String? = nil
	
	
	init(sinkCameraName: String)
	{
		let SinkPropertyKey = PopKinectWebcam.sinkPropertyName
		
		super.init()
		let deviceID = UUID()
		self.device = CMIOExtensionDevice(localizedName: sinkCameraName, deviceID: deviceID, legacyDeviceID: deviceID.uuidString, source: self)
		
		let dims = CMVideoDimensions(width: fixedCamWidth, height: fixedCamHeight)
		CMVideoFormatDescriptionCreate(
			allocator: kCFAllocatorDefault,
			codecType: kCVPixelFormatType_32BGRA,
			width: dims.width, height: dims.height, extensions: nil, formatDescriptionOut: &_videoDescription)
		
		let videoStreamFormat = CMIOExtensionStreamFormat.init(formatDescription: _videoDescription, maxFrameDuration: CMTime(value: 1, timescale: Int32(kFrameRate)), minFrameDuration: CMTime(value: 1, timescale: Int32(kFrameRate)), validFrameDurations: nil)
		
		let OutputUid = UUID()
		let SinkUid = UUID()
		outputStream = SinkOutputStream(localizedName: "\(sinkCameraName).OutputStream", streamID: OutputUid, streamFormat: videoStreamFormat, device: device)
		sink = SinkStream(localizedName: "\(sinkCameraName).Sink", streamID: SinkUid, streamFormat: videoStreamFormat, device: device, sinkPropertyKey: SinkPropertyKey)
		
		do
		{
			try device.addStream(outputStream.stream)
			try device.addStream(sink.stream)
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
		for client in self.sink.stream.streamingClients
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
			self.debugFrameSource.displayText = self.lastError ?? "Waiting app to connect"
			let Frame = try self.debugFrameSource.PopNewFrameSync()
			
			try self.outputStream.stream.send( Frame.sampleBuffer, discontinuity: [], hostTimeInNanoseconds: Frame.timeNanos )
			
			//	remove error
			self.lastError = nil
		}
		catch let error
		{
			//	display an error
			self.lastError = "\(error.localizedDescription)"
		}
	}
	
	
	func OnStreamObservedChanged() throws
	{
		if isStreamBeingWatched
		{
			try StartReadingFrames()
		}
		else
		{
			StopReadingFrames()
		}
	}
	
	func StartReadingFrames() throws
	{
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
	
	func StopReadingFrames()
	{
		if ( consumeSinkTimer != nil )
		{
			consumeSinkTimer!.cancel()
			consumeSinkTimer = nil
		}
	}
	
	func consumeOneBufferAsync(_ client: CMIOExtensionClient) async throws
	{
		do
		{
			let (Sample,SequenceNumber,Discontinuity,HasMoreSamples) = try await self.sink.stream.consumeSampleBuffer(from: client)
			let Now = CMClockGetTime(CMClockGetHostTimeClock())
			let NowNanos = UInt64(Now.seconds * Double(NSEC_PER_SEC))
			
			let output: CMIOExtensionScheduledOutput = CMIOExtensionScheduledOutput(sequenceNumber: SequenceNumber, hostTimeInNanoseconds:NowNanos)
			if self.isStreamBeingWatched
			{
				self.outputStream.stream.send(Sample, discontinuity: [], hostTimeInNanoseconds: UInt64(Sample.presentationTimeStamp.seconds * Double(NSEC_PER_SEC)))
			}
			self.sink.stream.notifyScheduledOutputChanged(output)
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
		self.sink.stream.consumeSampleBuffer(from: client)
		{
			sbuf, seq, discontinuity, hasMoreSampleBuffers, err in
			if let sbuf
			{
				let Now = CMClockGetTime(CMClockGetHostTimeClock())
				let NowNanos = UInt64(Now.seconds * Double(NSEC_PER_SEC))
				
				let output: CMIOExtensionScheduledOutput = CMIOExtensionScheduledOutput(sequenceNumber: seq, hostTimeInNanoseconds:NowNanos)
				if self.isStreamBeingWatched
				{
					self.outputStream.stream.send(sbuf, discontinuity: [], hostTimeInNanoseconds: UInt64(sbuf.presentationTimeStamp.seconds * Double(NSEC_PER_SEC)))
				}
				self.sink.stream.notifyScheduledOutputChanged(output)
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
