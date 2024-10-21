import Foundation
import CoreMediaIO
import Cocoa
import PopCameraDevice



class KinectStreamSource: NSObject, CMIOExtensionStreamSource
{
	var frameSource : FrameSource
	{
		kinectDevice.GetFrameSource()
	}
	
	
	var stream : CMIOExtensionStream!
	let device: CMIOExtensionDevice	//	parent
	var kinectDevice : KinectDeviceSource	{	return device.source as! KinectDeviceSource	}
	var supportedKinectFormats : [StreamImageFormat]

	//	we are/not supposed to be streaming
	var streamingRequested = false
	
	init(localizedStreamName: String, streamID: UUID, device: CMIOExtensionDevice, formats:[PopCameraDevice.StreamImageFormat])
	{
		self.supportedKinectFormats = formats
		
		let KinectSource = /*self.kinectDevice*/device.source as! KinectDeviceSource
		let label = "\(KinectSource.kinectDeviceMeta.Serial) \(localizedStreamName)"

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
		// An opportunity to inspect the client info and decide if it should be allowed to start the stream.
		return true
	}
	
	func startStream() throws
	{
		self.streamingRequested = true
	}
	
	func stopStream() throws
	{
		self.streamingRequested = false
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
	
	func FrameLoop() async
	{
		while ( true )
		{
			if !streamingRequested
			{
				//	todo: wait on a wake-up semaphore
				try! await Task.sleep(for: .seconds(1))
				continue
			}
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
				self.stream.send(sbuf, discontinuity: [], hostTimeInNanoseconds: UInt64(timingInfo.presentationTimeStamp.seconds * Double(NSEC_PER_SEC)))
				
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
	
}
