import AVFoundation
import Cocoa
import CoreMediaIO
import SystemExtensions


func GetExtensionBundle() -> Bundle
{
	let extensionsDirectoryURL = URL(fileURLWithPath: "Contents/Library/SystemExtensions", relativeTo: Bundle.main.bundleURL)
	let extensionURLs: [URL]
	do {
		extensionURLs = try FileManager.default.contentsOfDirectory(at: extensionsDirectoryURL,
																	includingPropertiesForKeys: nil,
																	options: .skipsHiddenFiles)
	} catch let error {
		fatalError("Failed to get the contents of \(extensionsDirectoryURL.absoluteString): \(error.localizedDescription)")
	}
	
	guard let extensionURL = extensionURLs.first else {
		fatalError("Failed to find any system extensions")
	}
	guard let extensionBundle = Bundle(url: extensionURL) else {
		fatalError("Failed to find any system extensions")
	}
	return extensionBundle
}


class ExtensionManager : NSObject, OSSystemExtensionRequestDelegate
{
	var logFunctor : (_ message:String) -> Void
	private var activating: Bool = false

	init(log: @escaping (_ message:String)->())
	{
		print("Allocating new CameraController")
		self.logFunctor = log
		
		super.init()
	}
	
	func showMessage(_ message:String)
	{
		self.logFunctor( message )
	}
	
	//	turn these into async funcs
	func ActivateCameraExtension()
	{
		guard let extensionIdentifier = GetExtensionBundle().bundleIdentifier else {
			return
		}
		self.activating = true
		let activationRequest = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: extensionIdentifier, queue: .main)
		activationRequest.delegate = self
		OSSystemExtensionManager.shared.submitRequest(activationRequest)
	}
	
	func DeactivateCameraExtension()
	{
		guard let extensionIdentifier = GetExtensionBundle().bundleIdentifier else {
			return
		}
		self.activating = false
		let deactivationRequest = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: extensionIdentifier, queue: .main)
		deactivationRequest.delegate = self
		OSSystemExtensionManager.shared.submitRequest(deactivationRequest)
	}
	
	
	
	func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
				 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction
	{
		showMessage("Replacing extension version \(existing.bundleShortVersion) with \(ext.bundleShortVersion)")
		return .replace
	}
	
	func requestNeedsUserApproval(_ request: OSSystemExtensionRequest)
	{
		showMessage("Extension needs user approval")
	}
	
	func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result)
	{
		showMessage("Request finished with result: \(result.rawValue)")
		
		//	gr: change this to promise resolution
		if result == .completed {
			if self.activating
			{
				showMessage("The camera is activated")
			} else {
				showMessage("The camera is deactivated")
			}
		} else {
			if self.activating {
				showMessage("Please reboot to finish installing extension")
			} else {
				showMessage("Please Reboot to finish deactivating the extension")
			}
		}
	}
	
	func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
		if self.activating {
			showMessage("Failed to activate the camera - \(error.localizedDescription)")
		} else {
			showMessage("Failed to deactivate the camera - \(error.localizedDescription)")
		}
	}
}
