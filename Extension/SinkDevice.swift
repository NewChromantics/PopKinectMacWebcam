import Foundation
import CoreMediaIO
import Cocoa
import PopCameraDevice




class SinkDeviceSource: NSObject, CMIOExtensionDeviceSource
{
	var device : CMIOExtensionDevice!
	var stream : SinkConsumerStreamSource!
	
	override init()
	{
		super.init()
		
		//	make the device
		let deviceUid = UUID()
		var DeviceName = "Sink Consumer Device"
		self.device = CMIOExtensionDevice(localizedName: DeviceName, deviceID: deviceUid, legacyDeviceID: deviceUid.uuidString, source: self)
				
		//	make the stream
		var StreamName = "Stream Name"
		let StreamUid = UUID()
		var StreamFormats = [StreamImageFormat(width: 123, height: 123, pixelFormat: kCVPixelFormatType_32BGRA)]
		stream = SinkConsumerStreamSource( localizedStreamName: StreamName, streamID: StreamUid, device: self.device, formats: StreamFormats)
		try! device.addStream(stream.stream!)
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
		//	based on.... properties?
		
		do
		{
			try stream.startStream()
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
			try stream.stopStream()
		}
		catch let error
		{
			print(error.localizedDescription)
		}
		
	}
	
}


