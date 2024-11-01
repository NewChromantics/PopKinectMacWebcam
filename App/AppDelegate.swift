import SwiftUI
import Foundation
import AppKit	//	uikit on ios

var TargetCameraName = "Sink Consumer Device"


@main
struct PopShaderCameraApp: App
{
	var sinkStreamPusher = SinkStreamPusher(cameraName: TargetCameraName)
	
	init()
	{
	}
	
	@NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
	
	var body: some Scene
	{
		WindowGroup
		{
			AppView()
				.environmentObject(sinkStreamPusher)
		}
		
	}

}


class AppDelegate: NSObject, NSApplicationDelegate
{
	func applicationDidFinishLaunching(_ aNotification: Notification) {
		// Insert code here to initialize your application
	}
	
	func applicationWillTerminate(_ aNotification: Notification) {
		// Insert code here to tear down your application
	}
	
	func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
		return true
	}
	
	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
		return true
	}
}
