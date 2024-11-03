import Foundation
import CoreMediaIO
import IOKit.audio
import os.log
import Cocoa





let kFrameRate: Int = 60
let fixedCamWidth: Int32 = 1280
let fixedCamHeight: Int32 = 720





class SinkOutputStream : NSObject, CMIOExtensionStreamSource
{
	private(set) var stream: CMIOExtensionStream!
	
	let parent : CMIOExtensionDevice	//	parent
	private let _streamFormat: CMIOExtensionStreamFormat
	var observerCounter = 0
	var isBeingObserved : Bool	{	return observerCounter > 0	}
	
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
		observerCounter += 1
		guard let deviceSource = parent.source as? SinkDevice else
		{
			fatalError("Unexpected source type \(String(describing: parent.source))")
		}
		
		try deviceSource.OnStreamObservedChanged()
	}
	
	func stopStream() throws
	{
		observerCounter -= 1
		guard let deviceSource = parent.source as? SinkDevice else
		{
			fatalError("Unexpected source type \(String(describing: parent.source))")
		}

		try deviceSource.OnStreamObservedChanged()
	}
}









class SinkStream: NSObject, CMIOExtensionStreamSource
{
	private(set) var stream: CMIOExtensionStream!
	let device: CMIOExtensionDevice
	private let _streamFormat: CMIOExtensionStreamFormat
	var client: CMIOExtensionClient?
	
	var sinkPropertyKey : String
	let sinkProperty : CMIOExtensionProperty
	var sinkPropertyValue : String
	
	init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice, sinkPropertyKey:String, sinkPropertyValue:String)
	{
		self.sinkPropertyKey = sinkPropertyKey
		self.sinkPropertyValue = sinkPropertyValue
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


