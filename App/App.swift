import SwiftUI


private var cameraControllerInstance : CameraController? = nil

@main
struct PopShaderCameraApp: App
{
	var body: some Scene
	{
		WindowGroup
		{
			AppView()
		}
		
	}
}



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
			cameraControllerInstance = CameraController( log:DefaultLog )
			DefaultLog("Created Camera")
		}
		DefaultLog("Init app view")
	}
	
	func DefaultLog(_ message:String)
	{
		cameraDebug.append(message)
		print(message)
	}

	func OnActivateExtension()
	{
		DefaultLog("Clicked activate")
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
			
			
			Text(cameraDebug.log)
				.frame(maxWidth: .infinity,maxHeight: .infinity, alignment: .topLeading)
				.padding(10)
				.lineLimit(nil)
				.textSelection(.enabled)
				.background( Color( NSColor.textBackgroundColor) )
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
