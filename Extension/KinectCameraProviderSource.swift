import Foundation
import CoreMediaIO
import IOKit.audio
import os.log
import Cocoa
import PopCameraDevice

var TargetCameraName = "Sink Consumer Device"

extension String
{
	func removePrefix(_ prefix: String) -> String
	{
		guard self.hasPrefix(prefix) else { return self }
		return String(self.dropFirst(prefix.count))
	}
}




class KinectCameraProviderSource : NSObject, CMIOExtensionProviderSource
{
	private(set) var provider: CMIOExtensionProvider!
	
	var devices : [String:CMIOExtensionDeviceSource] = [:]
	//var sinkDevice : SinkDeviceSource
	var sinkDevice : cameraDeviceSource

	init(clientQueue: DispatchQueue?)
	{
		//	make the sink device
		//sinkDevice = SinkDeviceSource()
		sinkDevice = cameraDeviceSource(localizedName: TargetCameraName)

		super.init()

		provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)

		try! provider.addDevice(sinkDevice.device)
		
		Task
		{
			await WatchForNewDevicesThread()
		}
		
	}
	
	func WatchForNewDevicesThread() async
	{
		while ( true )
		{
			do
			{
				try await Task.sleep(for: .seconds(1))
			}
			catch let Error
			{
				print("WatchForNewDevicesThread sleep error \(Error.localizedDescription)")
				return
			}
			
			do
			{
				let Devices = try PopCameraDevice.EnumDevices(requireSerialPrefix: "Freenect:")
				OnFoundDevices( Devices )
			}
			catch let error
			{
				print("Error enumerating devices; \(error.localizedDescription)")
			}
		}
	}
	
	func OnFoundDevice(_ deviceMeta:PopCameraDevice.EnumDeviceMeta) throws
	{
		func MatchDevice(element:Dictionary<String,CMIOExtensionDeviceSource>.Element) -> Bool
		{
			return element.key == deviceMeta.Serial
		}
		
		//	already found
		if ( devices.contains(where: MatchDevice) )
		{
			return;
		}
		
		//	make a new device
		let device = KinectDeviceSource(deviceMeta)
		try provider.addDevice(device.device)
		self.devices[deviceMeta.Serial] = device
	}
	
	func OnFoundDevices(_ deviceMetas:[PopCameraDevice.EnumDeviceMeta])
	{
		for deviceMeta in deviceMetas
		{
			do
			{
				try OnFoundDevice(deviceMeta)
			}
			catch let error
			{
				fatalError("Failed to add device '\(deviceMeta.Serial)': \(error.localizedDescription)")
			}
		}
	}
	
	func connect(to client: CMIOExtensionClient) throws
	{
		print("client \(client.signingID) connected")
	}
	
	func disconnect(from client: CMIOExtensionClient)
	{
		print("client \(client.signingID) disconnected")
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

