import SwiftUI
import AVFoundation
import PopCameraDevice
import WebGPU

//	webgpu has a .Color too, make life simpler
typealias Color = SwiftUI.Color


//	allow slider (anything) to bind an int to a float binding
//	https://stackoverflow.com/questions/65736518/how-do-i-create-a-slider-in-swiftui-bound-to-an-int-type-property
public extension Binding {
	
	static func convert<TInt, TFloat>(_ intBinding: Binding<TInt>) -> Binding<TFloat>
	where TInt:   BinaryInteger,
		  TFloat: BinaryFloatingPoint{
			  
			  Binding<TFloat> (
				get: { TFloat(intBinding.wrappedValue) },
				set: { intBinding.wrappedValue = TInt($0) }
			  )
		  }
	
	static func convert<TFloat, TInt>(_ floatBinding: Binding<TFloat>) -> Binding<TInt>
	where TFloat: BinaryFloatingPoint,
		  TInt:   BinaryInteger {
			  
			  Binding<TInt> (
				get: { TInt(floatBinding.wrappedValue) },
				set: { floatBinding.wrappedValue = TFloat($0) }
			  )
		  }
}

let inst = createInstance()


//	nil as it needs some callbacks, so has to be created by the app(view)
private var extensionManagerInstance : ExtensionManager? = nil

var appDebugFrameSource = DebugFrameSource(displayText: "Hello", clearColour: NSColor.green.cgColor)



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

extension Color
{
	static var buttonColor : Color	{	Color(NSColor.controlColor)	}
}
extension ShapeStyle where Self == Color
{
	static var buttonColor : Color	{	Color.buttonColor	}
}

struct OutlineButtonStyle : ButtonStyle
{
	var backgroundColour : Color = Color.buttonColor
	var isHovered : Bool
	
	
	func makeBody(configuration: Configuration) -> some View
	{
		let alpha = isHovered ? 1.0 : 0.01
		let bgColour = backgroundColour.opacity(alpha)
		
		configuration.label
			.background(
				RoundedRectangle(cornerRadius: 10)
					.stroke(backgroundColour,lineWidth: 1)
					//.fill(bgColour)
					.background(bgColour)
					.clipShape(RoundedRectangle(cornerRadius: 10))
			)
			//.padding(.horizontal)
	}
}

struct CameraDeviceButton : View
{
	var deviceMeta : PopCameraDevice.EnumDeviceMeta
	var active : Bool
	var accentColour : Color
	{
		return active ? Color("CameraDevice_Active") : Color("CameraDevice_Inactive")
	}
	var foregroundColour : Color
	{
		return isHovered ? Color.buttonColor : accentColour
	}
	var backgroundColour : Color
	{
		return isHovered ? accentColour : Color.buttonColor
	}
	let maxButtonWidth : CGFloat = .infinity	//	inf means it will fill width in hstack
	let maxButtonHeight : CGFloat = 80
	let iconSize : CGFloat = 30//UIDevice.current.localizedModel == "iPad" ? 100 : 50
	let iconCornerRadius : CGFloat = 10
	var onClicked : () -> Void
	@State var isHovered = false
	
	var label : String
	{
		return deviceMeta.Serial.replacingOccurrences(of: " ", with: "\n")
	}
	
	var body: some View
	{
		Button(action:onClicked)
		{
			VStack
			{
				Image(systemName:"web.camera.fill")
					.resizable()
					.aspectRatio(contentMode: .fit)
					.font(.system(size: iconSize))
					.foregroundColor(foregroundColour)
					.frame(width:iconSize, height:iconSize)
					//.padding(.top)

				Text(label)
					//.foregroundColor(foregroundColour)
					//.padding(.horizontal)
					//.frame(width: iconSize, height: iconSize)
			}
			//.frame here dictates the clickable area
			.frame(maxWidth: maxButtonWidth,maxHeight: maxButtonHeight)
			.onHover(perform: {newState in isHovered = newState })
		}
		.buttonStyle(OutlineButtonStyle(backgroundColour:self.backgroundColour,isHovered:self.isHovered))
		.controlSize(.regular)
	}
}



struct AppView : View
{
	var extensionManager : ExtensionManager {	return extensionManagerInstance!	}
	@ObservedObject var cameraDebug = LogBuffer()
	@EnvironmentObject var sinkStreamPusher : SinkStreamPusher
	@EnvironmentObject var popCameraDeviceManager : PopCameraDeviceManager
	@State var activeDeviceSerial : String?
	let debugSourceSerial = "Debug"
	@State var depthParams = DepthParams()	//	todo: bind directly(possible?) to frame source variables

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

	func OnClickedDeviceButton(_ serial:String)
	{
		if let currentActive = activeDeviceSerial
		{
			self.sinkStreamPusher.frameSource = nil
			activeDeviceSerial = nil
			//	turning current one off - dont start it again
			if ( currentActive == serial )
			{
				return
			}
		}

		//	start new frame source
		if ( serial == debugSourceSerial )
		{
			self.sinkStreamPusher.frameSource = appDebugFrameSource
		}
		else
		{
			//	gr: do we need to save this??
			self.sinkStreamPusher.frameSource = PopCameraDeviceFrameSource(deviceSerial: serial)
		}
		activeDeviceSerial = serial
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
			
			HStack()
			{
				Text("Pusher state: \(sinkStreamPusher.threadState)")
			}
			
			HStack()
			{
				if true //( popCameraDeviceManager.devices.isEmpty )
				{
					let deviceMeta = PopCameraDevice.EnumDeviceMeta(Serial:debugSourceSerial)
					let isActive = activeDeviceSerial == deviceMeta.Serial
					CameraDeviceButton(deviceMeta: deviceMeta, active: isActive, onClicked:{OnClickedDeviceButton(deviceMeta.Serial)} )
				}
				ForEach( popCameraDeviceManager.devices, id: \.Serial)
				{
					deviceMeta in
					let isActive = activeDeviceSerial == deviceMeta.Serial
					CameraDeviceButton(deviceMeta: deviceMeta, active: isActive, onClicked:{OnClickedDeviceButton(deviceMeta.Serial)} )
				}
			}
			.padding(.horizontal)
			
			HStack
			{
				CameraPreview()
					.environmentObject(sinkStreamPusher)
			
				VStack
				{
					if ( sinkStreamPusher.frameSource is PopCameraDeviceFrameSource )
					{
						Text("Depth range of \(depthParams.depthClipNear)...\(depthParams.depthClipFar)mm")
						
						//	todo: make a 2 headed slider
						//	gr: ^^^ i already wrote one!
						Slider(value: .convert($depthParams.depthClipNear), in: 1...65535)
							.onChange(of: depthParams.depthClipNear)
						{
							let framesource = sinkStreamPusher.frameSource as! PopCameraDeviceFrameSource
							framesource.depthParams = self.depthParams
						}
						
						Slider(value: .convert($depthParams.depthClipFar), in: 1...65535)
							.onChange(of: depthParams.depthClipFar)
						{
							let framesource = sinkStreamPusher.frameSource as! PopCameraDeviceFrameSource
							framesource.depthParams = self.depthParams
						}
						
					}
				}
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
