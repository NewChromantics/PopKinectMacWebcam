import SwiftUI
import AVFoundation

private var cameraControllerInstance : CameraController? = nil

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
	var cameraController : CameraController {	return cameraControllerInstance!	}
	@ObservedObject var cameraDebug = LogBuffer()

	init()
	{
		if ( cameraControllerInstance == nil )
		{
			cameraControllerInstance = CameraController( log:DebugLog )
			DebugLog("Created Camera")
		}
		DebugLog("Init app view")
		ListCameraDeviceNames()
	}
	
	func DebugLog(_ message:String)
	{
		cameraDebug.append(message)
		print(message)
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
	
	func ListCameraDeviceNames()
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
	
	
	func OnActivateExtension()
	{
		cameraController.activateCamera()
	}
	
	func OnDeactivateExtension()
	{
		cameraController.deactivateCamera()
	}
	
	func OnClearLog()
	{
		cameraDebug.Clear()
	}

	var body: some View
	{
		VStack(spacing: 20)
		{
			Text("Shader Camera")
				.font(.title)
			HStack()
			{
				Button("Install Extension",action:OnActivateExtension)
				Button("Remove Extension",action:OnDeactivateExtension)
			}
			Button("List Cameras",action:ListCameraDeviceNames)
			
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
