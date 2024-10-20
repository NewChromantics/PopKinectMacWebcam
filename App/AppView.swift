import SwiftUI
import AVFoundation
import PopCameraDevice

//	nil as it needs some callbacks, so has to be created by the app(view)
private var extensionManagerInstance : ExtensionManager? = nil



class LogBuffer : ObservableObject
{
	@Published var lines = [String]()
	var log : String	{	return lines.joined(separator: "\n")	}

	func append(_ message:String)
	{
		lines.append(message)
		objectWillChange.send()
	}
	
	func Clear()
	{
		lines = [String]()
	}
}


struct AppView : View
{
	var extensionManager : ExtensionManager {	return extensionManagerInstance!	}
	@ObservedObject var cameraDebug = LogBuffer()

	init()
	{
		if ( extensionManagerInstance == nil )
		{
			extensionManagerInstance = ExtensionManager( log:DebugLog )
			DebugLog("Created Camera")
		}
		DebugLog("Init app view")
	}
	
	func DebugLog(_ message:String)
	{
		cameraDebug.append(message)
		print(message)
	}
	
	func getAllKinectNames() throws -> [String]
	{
		let DeviceMetas = try PopCameraDevice.EnumDevices(requireSerialPrefix: "Freenect:")
		
		var deviceNames = DeviceMetas.map
		{
			device in
			"\(device.Serial)"
		}
		if ( DeviceMetas.count == 0 )
		{
			deviceNames.append("No Kinects")
		}
		return deviceNames
	}

	func getAllCaptureDeviceNames() throws -> [String]
	{
		var devices: [AVCaptureDevice]?
		if #available(macOS 10.15, *) {
			let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.externalUnknown],
																	mediaType: .video,
																	position: .unspecified)
			devices = discoverySession.devices
		}
		else
		{
			// Fallback on earlier versions
			devices = AVCaptureDevice.devices(for: .video)
		}
		
		guard let devices = devices else
		{
			throw RuntimeError("Failed to list camera devices")
		}
		
		var deviceNames = devices.map
		{
			device in
			"\(device.localizedName) [\(device.uniqueID)]"
		}
		if ( devices.count == 0 )
		{
			deviceNames.append("No cameras")
		}
		return deviceNames
	}
	
	func ListCameraNames()
	{
		do
		{
			DebugLog( try getAllCaptureDeviceNames().joined(separator: "\n"))
		}
		catch let error
		{
			DebugLog("Error getting cameras \(error.localizedDescription)")
		}
	}
	
	func ListKinectNames()
	{
		do
		{
			DebugLog( try getAllKinectNames().joined(separator: "\n"))
		}
		catch let error
		{
			DebugLog("Error getting Kinects \(error.localizedDescription)")
		}
	}
	
	
	//	gr: i want to make these async...
	func OnActivateExtension()
	{
		extensionManager.ActivateCameraExtension()
	}
	
	func OnDeactivateExtension()
	{
		extensionManager.DeactivateCameraExtension()
	}
	
	func OnClearLog()
	{
		cameraDebug.Clear()
	}

	var body: some View
	{
		VStack(spacing: 20)
		{
			Text("Pop Kinect Webcam")
				.font(.title)
			let LibVersion = PopCameraDevice.GetVersion()
			Text("PopCameraDevice Version \(LibVersion)")
				.font(.subheadline)
			
			HStack()
			{
				Button("Install Extension",action:OnActivateExtension)
				Button("Remove Extension",action:OnDeactivateExtension)
				Button("List Cameras",action:ListCameraNames)
				Button("List Kinects",action:ListKinectNames)
			}
			
			ScrollView
			{
				VStack
				{
					Text(cameraDebug.log)
						.frame(maxWidth: .infinity,maxHeight: .infinity, alignment: .topLeading)
						.padding(10)
						.lineLimit(nil)
						.textSelection(.enabled)
						.background( Color( NSColor.textBackgroundColor) )
				}
			}
			Button("Clear Log",action:OnClearLog)
		}
	}
}

struct AppView_Previews: PreviewProvider
{
	static var previews: some View
	{
		AppView()
	}
}
