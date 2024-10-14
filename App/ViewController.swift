import Cocoa


class ViewController: NSViewController
{
	private var cameraControllerInstance : CameraController? = nil
	var cameraController : CameraController {	return cameraControllerInstance!	}
	private var debugCaption: NSTextField!
	private var needToStreamCaption: NSTextField!

	@objc func activate(_ sender: Any? = nil) {
		cameraController.activateCamera()
	}

	@objc func deactivate(_ sender: Any? = nil) {
		cameraController.deactivateCamera()
	}


	override func viewDidLoad() {
		super.viewDidLoad()

		let button = NSButton(title: "activate", target: self, action: #selector(activate(_:)))
		self.view.addSubview(button)

		let button2 = NSButton(title: "deactivate", target: self, action: #selector(deactivate(_:)))
		self.view.addSubview(button2)
		button2.frame = CGRect(x: 120, y: 0, width: button2.frame.width, height: button.frame.height)

		debugCaption = fakeLabel("")
		debugCaption.isEditable = false
		let frame = self.view.frame
		debugCaption.frame = frame.insetBy(dx: 0, dy: 32)
		self.view.addSubview(debugCaption)

		needToStreamCaption = fakeLabel("need to stream = ???")
		needToStreamCaption.frame = needToStreamCaption.frame.offsetBy(dx: button2.frame.maxX + 16, dy: 4)
		self.view.addSubview(needToStreamCaption)
		cameraControllerInstance = CameraController( log: showMessage )
		
		cameraController.registerForDeviceNotifications()

		cameraController.makeDevicesVisible()
		//cameraController.connectToCamera()
		cameraController.initTimer()
	}

	func showMessage(_ text: String) {
		print("showMessage",text)
		debugCaption.stringValue += "\(text)\n"
	}
	
	func fakeLabel(_ text: String) -> NSTextField {
		let label = NSTextField()
		label.frame = CGRect(origin: .zero, size: CGSize(width: 200, height: 24))
		label.stringValue = text
		label.backgroundColor = .clear
		//label.isBezeled = false
		label.isEditable = false
		//label.sizeToFit()
		return label
	}
	
	

	override var representedObject: Any? {
		didSet {
		// Update the view, if already loaded.
		}
	}


}
