import Foundation
import CoreMediaIO
import Cocoa
import PopCameraDevice

func GetNiceKinectName(_ device:PopCameraDevice.EnumDeviceMeta) -> String
{
	var Serial = device.Serial
	Serial = Serial.removePrefix("Freenect:")
	return "Kinect \(Serial)"
}

func GetColour(_ named:String) -> CGColor
{
	let Colour = NSColor(named: named)
	return Colour?.cgColor ?? NSColor.red.cgColor
}


class KinectDeviceSource: NSObject, CMIOExtensionDeviceSource
{
	var device : CMIOExtensionDevice!
	var colourStreamSource: KinectStreamSource!
	var depthStreamSource: KinectStreamSource!
	let kinectDeviceMeta : PopCameraDevice.EnumDeviceMeta
	
	
	

	init(_ deviceMeta:PopCameraDevice.EnumDeviceMeta)
	{
		self.kinectDeviceMeta = deviceMeta
		
		super.init()
		
		let localizedName = GetNiceKinectName(deviceMeta)
		
		let deviceUid = UUID()
		self.device = CMIOExtensionDevice(localizedName: localizedName, deviceID: deviceUid, legacyDeviceID: deviceUid.uuidString, source: self)
				
		let colourUid = UUID()
		let depthUid = UUID()
		colourStreamSource = KinectStreamSource(localizedStreamName: "Colour", streamID: colourUid, device: device, backgroundColour:GetColour("StreamDebugColour") )
		depthStreamSource = KinectStreamSource(localizedStreamName: "Depth", streamID: depthUid, device: device, backgroundColour:GetColour("StreamDebugDepth") )

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


