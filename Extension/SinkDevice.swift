import Foundation
import CoreMediaIO
import Cocoa



class SinkDevice : NSObject, CMIOExtensionDeviceSource
{
	enum PopFrameResult
	{
		case MoreFramesPending
		case CanSleep
	}
		
	
	var debugFrameSource = DebugFrameSource(displayText: "Something", clearColour: NSColor.magenta.cgColor)
	
	var device: CMIOExtensionDevice!
	
	var outputStream : SinkOutputStream!
	var isStreamBeingWatched : Bool	{	return outputStream.isBeingObserved	}
	var sink : SinkStream!
	
	var _videoDescription: CMFormatDescription!

	var frameLoopTask : Task<Void,any Error>? = nil	//	if no task, we use timer
	let expectedFrameIntervalMs = 1000/60

	var isUsingTimer : Bool	{	frameLoopTask == nil	}
	var consumeSinkTimer: DispatchSourceTimer?
	let consumeSinkTimerQueue = DispatchQueue(label: "consumeSinkTimerQueue", qos: .userInteractive, attributes: [], autoreleaseFrequency: .workItem, target: .global(qos: .userInteractive))
	
	var lastError : String? = nil
	
	init(sinkCameraName: String)
	{
		let sinkPropertyKey = PopKinectWebcam.sinkPropertyKey
		let sinkPropertyValue = PopKinectWebcam.sinkPropertyValue
		debugFrameSource.displayText = sinkCameraName
		
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
		sink = SinkStream(localizedName: "\(sinkCameraName).Sink", streamID: SinkUid, streamFormat: videoStreamFormat, device: device, sinkPropertyKey: sinkPropertyKey, sinkPropertyValue: sinkPropertyValue)
		
		do
		{
			//	order doesnt matter, as we identify sink stream with a sink property
			//	if we dont have an output stream, the camera wont appear in common apps
			try device.addStream(outputStream.stream)
			try device.addStream(sink.stream)
		}
		catch let error
		{
			fatalError("Failed to add stream: \(error.localizedDescription)")
		}
		
		//	if we dont run this, we use a timer when stream starts
		frameLoopTask = Task
		{
			try await FrameLoop()
		}
	}
	
	deinit
	{
		frameLoopTask?.cancel()
		frameLoopTask = nil
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
	
	//	returns true if we know there's another frame queued up
	func UpdateFrameAsync() async -> PopFrameResult
	{
		//	if there are clients attached to the sink, consume from them
		for client in self.sink.stream.streamingClients
		{
			do
			{
				//	this async version will crash with a nil unwrap - but not sure why/where
				//try await self.consumeOneBufferAsync(client)
				let PopResult = try self.consumeOneBuffer(client)
				return PopResult
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
		//	then leave a bit of time to display the error
		return PopFrameResult.CanSleep
	}
	
	
	func OnStreamObservedChanged() throws
	{
		if isStreamBeingWatched
		{
			try StartConsumeTimer()
		}
		else
		{
			StopConsumeTimer()
		}
	}
	
	func FrameLoop() async throws
	{
		while ( !Task.isCancelled )
		{
			//	a sleep here will throw if the task is cancelled
			let UpdateResult = await self.UpdateFrameAsync()
			
			//	gr: we shouldn't have to sleep if the func above is blocking properly
			//		maybe change the result of UpdateFrameAsync to "Can sleep"
			if ( UpdateResult == PopFrameResult.CanSleep )
			{
				//	this throws if task cancelled
				try await Task.sleep(for:.milliseconds(expectedFrameIntervalMs))
			}
		}
	}
	
	func StartConsumeTimer() throws
	{
		if ( !isUsingTimer )
		{
			return
		}

		if ( consumeSinkTimer != nil )
		{
			return
		}

		consumeSinkTimer = DispatchSource.makeTimerSource(flags: .strict, queue: consumeSinkTimerQueue)
		guard let consumeSinkTimer else
		{
			throw RuntimeError("Failed to start timer")
		}
		
		consumeSinkTimer.schedule(deadline: .now(), repeating: .milliseconds(expectedFrameIntervalMs), leeway: .seconds(0))
		consumeSinkTimer.setEventHandler
		{
			//	gr: this is async to match the rest of the code
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
	
	func StopConsumeTimer()
	{
		if ( consumeSinkTimer != nil )
		{
			consumeSinkTimer!.cancel()
			consumeSinkTimer = nil
		}
	}
	
	func consumeOneBufferAsync(_ client: CMIOExtensionClient) async throws -> PopFrameResult
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
			return HasMoreSamples ? PopFrameResult.MoreFramesPending : PopFrameResult.CanSleep
		}
		catch let Error
		{
			let error = Error.localizedDescription
			throw RuntimeError("consumeOneBufferAsync Error \(error)")
		}
	}
	
	//	returns true if we know there are more frames to come
	func consumeOneBuffer(_ client: CMIOExtensionClient) throws -> PopFrameResult
	{
		//	todo: change this to a future?
		//	gr: it seems we just dont get a callback if there's no frame?
		var SomeError : String? = nil
		var HasMoreFrames : Bool?
		
		self.sink.stream.consumeSampleBuffer(from: client)
		{
			sbuf, seq, discontinuity, hasMoreSampleBuffers, err in
			HasMoreFrames = hasMoreSampleBuffers
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
		
		guard let HasMoreFrames else
		{
			//	gr: it s
			//throw RuntimeError("ConsumeOneBuffer never got a result")
			return PopFrameResult.CanSleep
		}
		return HasMoreFrames ? PopFrameResult.MoreFramesPending : PopFrameResult.CanSleep
	}
	
}
