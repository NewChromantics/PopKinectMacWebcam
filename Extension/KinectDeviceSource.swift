import Foundation
import CoreMediaIO
import Cocoa


class KinectDeviceSource: NSObject, CMIOExtensionDeviceSource
{
	var device : CMIOExtensionDevice!
	var colourStreamSource: KinectStreamSource!
	var depthStreamSource: KinectStreamSource!

	init(localizedName:String)
	{
		super.init()
		
		let deviceUid = UUID()
		self.device = CMIOExtensionDevice(localizedName: localizedName, deviceID: deviceUid, legacyDeviceID: deviceUid.uuidString, source: self)
				
		let colourUid = UUID()
		let depthUid = UUID()
		colourStreamSource = KinectStreamSource(localizedName: "Colour", streamID: colourUid, device: device, backgroundColour:NSColor.green.cgColor )
		depthStreamSource = KinectStreamSource(localizedName: "Depth", streamID: depthUid, device: device, backgroundColour:NSColor.blue.cgColor)

		try! device.addStream(colourStreamSource.stream)
		try! device.addStream(depthStreamSource.stream)
	}
	
	var availableProperties: Set<CMIOExtensionProperty> {
		
		return [.deviceTransportType, .deviceModel]
	}
	
	func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties
	{
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
	
	func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws
	{
		// Handle settable properties here.
	}
	
	func startStreaming()
	{
		do
		{
			try colourStreamSource.startStream()
		}
		catch let error
		{
			print(error.localizedDescription)
		}
		
		do
		{
			try depthStreamSource.startStream()
		}
		catch let error
		{
			print(error.localizedDescription)
		}
	}
	
	func stopStreaming()
	{
		do
		{
			try colourStreamSource.stopStream()
		}
		catch let error
		{
			print(error.localizedDescription)
		}
		
		do
		{
			try depthStreamSource.stopStream()
		}
		catch let error
		{
			print(error.localizedDescription)
		}
	}
}



class KinectStreamSource: NSObject, CMIOExtensionStreamSource
{
	var frameSource : FrameSource
	
	var stream : CMIOExtensionStream!
	let device: CMIOExtensionDevice	//	parent
	let streamFormat: CMIOExtensionStreamFormat
	
	init(localizedName: String, streamID: UUID, device: CMIOExtensionDevice, backgroundColour:CGColor)
	{
		self.device = device
		self.frameSource = DebugFrameSource(clearColour: backgroundColour)
		self.streamFormat = CMIOExtensionStreamFormat.init(formatDescription: frameSource.videoFormat, maxFrameDuration: frameSource.maxFrameDuration, minFrameDuration: frameSource.maxFrameDuration, validFrameDurations: nil)
		
		super.init()
		
		self.stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: .source, clockType: .hostTime, source: self)
		
		Task
		{
			await FrameLoop()
		}
	}
	
	var formats: [CMIOExtensionStreamFormat]
	{
		return [streamFormat]
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
	}
	
	func stopStream() throws
	{
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
