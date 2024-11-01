import AVFoundation
import Cocoa
import CoreMediaIO
import SystemExtensions


struct CameraStreamMeta
{
	var StreamId : CMIOStreamID
}

//	RAII interface to camera
class CameraWithSinkInterface
{
	var device : AVCaptureDevice
	var sinkQueue: CMSimpleQueue!

	var startedDeviceAndStream : (CMIOObjectID,CMIOStreamID)? = nil
	
	init(device: AVCaptureDevice) throws
	{
		self.device = device
		
		//	find the sink stream id
		let SinkStreamId = try GetSinkStreamId()
		
		//	bind to it
		try BindToSinkQueue(sinkStreamId: SinkStreamId)
	}
	
	deinit
	{
		Free()
	}
	
	func Free()
	{
		//	need to remove our pointer to CMIOStreamCopyBufferQueue
		print("Cleanup CMIOStreamCopyBufferQueue pointer reference")
		
		if let startedDeviceAndStream
		{
			let deviceId = startedDeviceAndStream.0
			let streamId = startedDeviceAndStream.1
			let StopDeviceResult = CMIODeviceStopStream(deviceId, streamId)
			if StopDeviceResult != 0
			{
				print("Warning CMIODeviceStopStream(\(deviceId),\(streamId)) failed; \(StopDeviceResult)")
			}
		}
		startedDeviceAndStream = nil
	}
	
	func GetCmioDeviceId(uid:String) throws -> CMIOObjectID
	{
		var dataSize: UInt32 = 0
		var devices = [CMIOObjectID]()
		var dataUsed: UInt32 = 0
		var opa = CMIOObjectPropertyAddress( CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices), .global, .main)
		CMIOObjectGetPropertyDataSize(CMIOObjectPropertySelector(kCMIOObjectSystemObject), &opa, 0, nil, &dataSize);
		let nDevices = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
		devices = [CMIOObjectID](repeating: 0, count: Int(nDevices))
		CMIOObjectGetPropertyData(CMIOObjectPropertySelector(kCMIOObjectSystemObject), &opa, 0, nil, dataSize, &dataUsed, &devices);
		for deviceObjectID in devices
		{
			opa.mSelector = CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID)
			CMIOObjectGetPropertyDataSize(deviceObjectID, &opa, 0, nil, &dataSize)
			var name: CFString = "" as NSString
			//CMIOObjectGetPropertyData(deviceObjectID, &opa, 0, nil, UInt32(MemoryLayout<CFString>.size), &dataSize, &name);
			CMIOObjectGetPropertyData(deviceObjectID, &opa, 0, nil, dataSize, &dataUsed, &name);
			if String(name) == uid {
				return deviceObjectID
			}
		}
		throw RuntimeError("Not found")
	}
	
	func GetInputStreamIds(deviceId: CMIODeviceID) -> [CMIOStreamID]
	{
		var dataSize: UInt32 = 0
		var dataUsed: UInt32 = 0
		var opa = CMIOObjectPropertyAddress(CMIOObjectPropertySelector(kCMIODevicePropertyStreams), .global, .main)
		CMIOObjectGetPropertyDataSize(deviceId, &opa, 0, nil, &dataSize);
		let numberStreams = Int(dataSize) / MemoryLayout<CMIOStreamID>.size
		var streamIds = [CMIOStreamID](repeating: 0, count: numberStreams)
		CMIOObjectGetPropertyData(deviceId, &opa, 0, nil, dataSize, &dataUsed, &streamIds)
		return streamIds
	}
	
	func GetSinkStreamId() throws -> CMIOStreamID
	{
		let DeviceUid = try GetCmioDeviceId(uid: device.uniqueID)
		
		let StreamIds = GetInputStreamIds(deviceId: DeviceUid)

		//	todo: more sophisticated sink stream detection
		//		ie. read a property we're looking for to identify it
		return StreamIds[1]
	}
	
	func BindToSinkQueue(sinkStreamId:CMIOStreamID) throws
	{
		//	allocate a pointer queue and save it
		let pointerQueue = UnsafeMutablePointer<Unmanaged<CMSimpleQueue>?>.allocate(capacity: 1)
		
		// see https://stackoverflow.com/questions/53065186/crash-when-accessing-refconunsafemutablerawpointer-inside-cgeventtap-callback
		//let SelfRef = UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque())
		let SelfRef = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
		
		guard let queue = pointerQueue.pointee else
		{
			throw RuntimeError("Stream queue missing pointer upon allocation")
		}
		
		//	gr: maybe we should be saving pointerQueue as a reference counted variable, if we're keeping an unretained one...
		sinkQueue = queue.takeUnretainedValue()
		
		
		
		let OnQueueAltered : CMIODeviceStreamQueueAlteredProc =
		{
			(sinkStream: CMIOStreamID, buf: UnsafeMutableRawPointer?, refCon: UnsafeMutableRawPointer?) in
			
			let ThisPointer = Unmanaged<CameraWithSinkInterface>.fromOpaque(refCon!)
			let This = ThisPointer.takeUnretainedValue()
			//This.readyToEnqueue = true
			print("Queue altered")
		}
		
		//	gr: this copies.... TO our pointer? to get a queue for....?
		let Result = CMIOStreamCopyBufferQueue(sinkStreamId,OnQueueAltered,SelfRef,pointerQueue)
		if Result != 0
		{
			throw RuntimeError("Error \(Result) from copy buffer queue")
		}
		
		let deviceId = try GetCmioDeviceId(uid: device.uniqueID)
		let StartDeviceResult = CMIODeviceStartStream(deviceId, sinkStreamId)
		if StartDeviceResult != 0
		{
			throw RuntimeError("Error \(StartDeviceResult) from starting sink stream")
		}
		startedDeviceAndStream = (deviceId,sinkStreamId)
	}
}

//	this class looks for a camera wth a sink stream we can push to
//	it then delivers any frames pushed in
class SinkStreamPusher : NSObject, ObservableObject
{
	//var logFunctor : (_ message:String) -> Void
	//@Published public var state = SinkStreamPusherState()
	@Published public var threadState : String = "Init"
	var threadStateString : String
	{
		get
		{
			return threadState
		}
		set(newValue)
		{
			DispatchQueue.main.async
			{
				self.threadState = newValue
			}
		}
	}
	
	
	//	variables to help us find what camera & stream we want to write to
	var targetCameraName : String
	//	sink stream key
	
	var Freed = false
	
	
	private var needToStream: Bool = false
	private var testImage = NSImage(named: "TestImage")
	private var activating: Bool = false
	private var readyToEnqueue = false
	private var enqueued = false
	private var _videoDescription: CMFormatDescription!
	private var _bufferPool: CVPixelBufferPool!
	private var _bufferAuxAttributes: NSDictionary!
	private var _whiteStripeStartRow: UInt32 = 0
	private var _whiteStripeIsAscending: Bool = false
	private var overlayMessage: Bool = false
	private var sequenceNumber = 0
	private var SendImageTimer: Timer?
	private var ReadPropertyTimer: Timer?
	var SendImageIntervalSecs = 1/CGFloat(60)
	var ReadPropertyIntervalSecs = 2.0
	
	var sourceStream: CMIOStreamID?
	//var sinkStream: CMIOStreamID?
	
	init(cameraName:String/*,log: @escaping (_ message:String)->()*/)
	{
		print("Allocating new CameraController")
		//self.logFunctor = log
		self.targetCameraName = cameraName
		
		super.init()
		/*
		self.registerForDeviceNotifications()
		self.makeDevicesVisible()
		self.connectToCamera()
		self.initTimer()
		 */
		Task
		{
			await Thread()
		}
	}
	
	deinit
	{
		Free()
	}
	
	func Free()
	{
		self.Freed = true
	}
	
	func Log(_ message:String)
	{
		//self.logFunctor( message )
		print(message)
	}
	
	func OnError(_ message:String)
	{
		Log("Error: \(message)")
	}
	
	func Thread() async
	{
		while ( !Freed )
		{
			do
			{
				threadStateString = "Looking for camera..."
				let Camera = try await FindCamera()
				try await SendFramesToStream(camera:Camera)
			}
			catch let Error
			{
				OnError(Error.localizedDescription)
				threadStateString = "Error: \(Error.localizedDescription)"
				
				//	breath between errors
				try! await Task.sleep( for:.seconds(1) )
			}
		}
	}
	
	func GetCameraDeviceWithName(_ name: String) -> AVCaptureDevice?
	{
		var devices: [AVCaptureDevice]?
		if #available(macOS 10.15, *) {
			let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.externalUnknown],
																	mediaType: .video,
																	position: .unspecified)
			devices = discoverySession.devices
		} else {
			// Fallback on earlier versions
			devices = AVCaptureDevice.devices(for: .video)
		}
		guard let devices = devices else { return nil }
		return devices.first { $0.localizedName == name}
	}
	
	func FindCamera() async throws -> CameraWithSinkInterface
	{
		let Device = GetCameraDeviceWithName(targetCameraName)
		guard let Device else
		{
			throw RuntimeError("No camera named \(targetCameraName)")
		}

		return try CameraWithSinkInterface(device:Device)
	}
	
	func SendFramesToStream(camera:CameraWithSinkInterface) async throws
	{
		throw RuntimeError("todo: get frames to send to sink")
	}
	
/*
	func getProperty(streamId: CMIOStreamID,key:String) throws -> String
	{
		let selector = FourCharCode(key)
		var address = CMIOObjectPropertyAddress(selector, .global, .main)
		let exists = CMIOObjectHasProperty(streamId, &address)
		if ( !exists )
		{
			throw RuntimeError("Missing property \(key)")
		}
		
		var dataSize: UInt32 = 0
		var dataUsed: UInt32 = 0
		CMIOObjectGetPropertyDataSize(streamId, &address, 0, nil, &dataSize)
		var name: CFString = "" as NSString
		CMIOObjectGetPropertyData(streamId, &address, 0, nil, dataSize, &dataUsed, &name);
		return name as String
	}
	
	func setProperty(streamId: CMIOStreamID, newValue: String, key: String) throws
	{
		let selector = FourCharCode(key)
		var address = CMIOObjectPropertyAddress(selector, .global, .main)
		let exists = CMIOObjectHasProperty(streamId, &address)
		if ( !exists )
		{
			throw RuntimeError("No such property \(key)")
		}
		
		var IsWritable : DarwinBoolean = false
		CMIOObjectIsPropertySettable(streamId,&address,&IsWritable)
		if ( IsWritable == false )
		{
			throw RuntimeError("Property \(key) is not Settable")
		}
		
		//	write string into the data
		var dataSize: UInt32 = 0
		CMIOObjectGetPropertyDataSize(streamId, &address, 0, nil, &dataSize)
		var newName: CFString = newValue as NSString
		//var value : UnsafePointer = (newValue as NSString).utf8String!
		CMIOObjectSetPropertyData(streamId, &address, 0, nil, dataSize, &newName )
	}
	
	func makeDevicesVisible(){
		var prop = CMIOObjectPropertyAddress(
			mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
			mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
			mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
		var allow : UInt32 = 1
		let dataSize : UInt32 = 4
		let zero : UInt32 = 0
		CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &prop, zero, nil, dataSize, &allow)
	}
	
	
	func initSink(deviceId: CMIODeviceID, sinkStream: CMIOStreamID)
	{
		let dims = CMVideoDimensions(width: fixedCamWidth, height: fixedCamHeight)
		CMVideoFormatDescriptionCreate(
			allocator: kCFAllocatorDefault,
			codecType: kCVPixelFormatType_32BGRA,
			width: dims.width, height: dims.height, extensions: nil, formatDescriptionOut: &_videoDescription)
		
		var pixelBufferAttributes: NSDictionary!
		pixelBufferAttributes = [
			kCVPixelBufferWidthKey: dims.width,
			kCVPixelBufferHeightKey: dims.height,
			kCVPixelBufferPixelFormatTypeKey: _videoDescription.mediaSubType,
			kCVPixelBufferIOSurfacePropertiesKey: [:]
		]
		
		CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, pixelBufferAttributes, &_bufferPool)
		
		let pointerQueue = UnsafeMutablePointer<Unmanaged<CMSimpleQueue>?>.allocate(capacity: 1)
		// see https://stackoverflow.com/questions/53065186/crash-when-accessing-refconunsafemutablerawpointer-inside-cgeventtap-callback
		//let pointerRef = UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque())
		let pointerRef = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
		let result = CMIOStreamCopyBufferQueue(sinkStream,
											   {
			(sinkStream: CMIOStreamID, buf: UnsafeMutableRawPointer?, refcon: UnsafeMutableRawPointer?) in
			let sender = Unmanaged<CameraController>.fromOpaque(refcon!).takeUnretainedValue()
			sender.readyToEnqueue = true
		},pointerRef,pointerQueue)
		if result != 0 {
			showMessage("error starting sink")
		} else {
			if let queue = pointerQueue.pointee {
				self.sinkQueue = queue.takeUnretainedValue()
			}
			let resultStart = CMIODeviceStartStream(deviceId, sinkStream) == 0
			if resultStart {
				showMessage("initSink started")
			} else {
				showMessage("initSink error startstream")
			}
		}
	}
 

	
	func getDevice(name: String) -> AVCaptureDevice? {
		print("getDevice name=",name)
		var devices: [AVCaptureDevice]?
		if #available(macOS 10.15, *) {
			let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.externalUnknown],
																	mediaType: .video,
																	position: .unspecified)
			devices = discoverySession.devices
		} else {
			// Fallback on earlier versions
			devices = AVCaptureDevice.devices(for: .video)
		}
		guard let devices = devices else { return nil }
		return devices.first { $0.localizedName == name}
	}
	
	
	
	func connectToCamera()
	{
		if let device = getDevice(name: cameraName), let deviceObjectId = getCMIODevice(uid: device.uniqueID) {
			let streamIds = getInputStreams(deviceId: deviceObjectId)
			if streamIds.count == 2
			{
				sinkStream = streamIds[1]
				showMessage("found sink stream")
				initSink(deviceId: deviceObjectId, sinkStream: streamIds[1])
			}
			if let firstStream = streamIds.first
			{
				showMessage("found source stream")
				sourceStream = firstStream
			}
		}
	}
	
	func initTimer()
	{
		SendImageTimer?.invalidate()
		SendImageTimer = Timer.scheduledTimer(timeInterval: SendImageIntervalSecs, target: self, selector: #selector(OnSendImageTimerTick), userInfo: nil, repeats: true)
		
		ReadPropertyTimer?.invalidate()
		ReadPropertyTimer = Timer.scheduledTimer(timeInterval: ReadPropertyIntervalSecs, target: self, selector: #selector(OnPropertyTimerTick), userInfo: nil, repeats: true)
	}
	
	@objc func OnSendImageTimerTick() {
		if needToStream {
			if (enqueued == false || readyToEnqueue == true), let queue = self.sinkQueue {
				enqueued = true
				readyToEnqueue = false
				if let image = testImage, let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
					self.enqueue(queue, cgImage)
				}
			}
		}
	}

	
	@objc func OnPropertyTimerTick()
	{
		if let sourceStream = sourceStream
		{
			//	clear the SinkCounter property
			//	then re-read it
			do
			{
				try self.setProperty(streamId: sourceStream, newValue: "random", key:"just")
				let just = try self.getProperty(streamId: sourceStream, key:"just")
				
				if just == "SinkConsumerCounter=1" {
					needToStream = true
				} else {
					needToStream = false
				}
			}
			catch let error
			{
				OnError( error.localizedDescription )
			}
		}
	}
	
	func OnNewCameraDeviceConnected(notification:Notification)
	{
		if ( notification.name != NSNotification.Name.AVCaptureDeviceWasConnected )
		{
			return
		}
		
		//	gr: Im not sure how to get any more info out of this Notification type - what can i cast .object to?
		let device = notification.object as! AVCaptureDevice?
		var DeviceName = "null"
		if let device
		{
			let DeviceType = type(of:device)
			//let DeviceType = device.deviceType
			DeviceName = "\(device.localizedName) (\(DeviceType)) [\(device.uniqueID)]"
		}
		//showMessage("New camera device connected; \(notification.description)")
		showMessage("New camera device connected; \(DeviceName)")
		if self.sourceStream == nil
		{
			//self.connectToCamera()
		}
	}
	
	func registerForDeviceNotifications()
	{
		NotificationCenter.default.addObserver(forName: NSNotification.Name.AVCaptureDeviceWasConnected, object: nil, queue: nil, using:OnNewCameraDeviceConnected )
	}
	
	
	
	func enqueue(_ queue: CMSimpleQueue, _ image: CGImage) {
		guard CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else {
			print("error enqueuing")
			return
		}
		var err: OSStatus = 0
		var pixelBuffer: CVPixelBuffer?
		err = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, self._bufferPool, self._bufferAuxAttributes, &pixelBuffer)
		if let pixelBuffer = pixelBuffer {
			
			CVPixelBufferLockBaseAddress(pixelBuffer, [])
			
			/*var bufferPtr = CVPixelBufferGetBaseAddress(pixelBuffer)!
			 let width = CVPixelBufferGetWidth(pixelBuffer)
			 let height = CVPixelBufferGetHeight(pixelBuffer)
			 let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
			 memset(bufferPtr, 0, rowBytes * height)
			 
			 let whiteStripeStartRow = self._whiteStripeStartRow
			 if self._whiteStripeIsAscending {
			 self._whiteStripeStartRow = whiteStripeStartRow - 1
			 self._whiteStripeIsAscending = self._whiteStripeStartRow > 0
			 }
			 else {
			 self._whiteStripeStartRow = whiteStripeStartRow + 1
			 self._whiteStripeIsAscending = self._whiteStripeStartRow >= (height - kWhiteStripeHeight)
			 }
			 bufferPtr += rowBytes * Int(whiteStripeStartRow)
			 for _ in 0..<kWhiteStripeHeight {
			 for _ in 0..<width {
			 var white: UInt32 = 0xFFFFFFFF
			 memcpy(bufferPtr, &white, MemoryLayout.size(ofValue: white))
			 bufferPtr += MemoryLayout.size(ofValue: white)
			 }
			 }*/
			let pixelData = CVPixelBufferGetBaseAddress(pixelBuffer)
			let width = CVPixelBufferGetWidth(pixelBuffer)
			let height = CVPixelBufferGetHeight(pixelBuffer)
			let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
			// optimizing context: interpolationQuality and bitmapInfo
			// see https://stackoverflow.com/questions/7560979/cgcontextdrawimage-is-extremely-slow-after-large-uiimage-drawn-into-it
			if let context = CGContext(data: pixelData,
									   width: width,
									   height: height,
									   bitsPerComponent: 8,
									   bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
									   space: rgbColorSpace,
									   //bitmapInfo: UInt32(CGImageAlphaInfo.noneSkipFirst.rawValue) | UInt32(CGImageByteOrderInfo.order32Little.rawValue))
									   bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
			{
				context.interpolationQuality = .low
				context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
			}
			CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
			
			var sbuf: CMSampleBuffer!
			var timingInfo = CMSampleTimingInfo()
			timingInfo.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock())
			err = CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: self._videoDescription, sampleTiming: &timingInfo, sampleBufferOut: &sbuf)
			if err == 0 {
				if let sbuf = sbuf {
					let pointerRef = UnsafeMutableRawPointer(Unmanaged.passRetained(sbuf).toOpaque())
					CMSimpleQueueEnqueue(queue, element: pointerRef)
				}
			}
		} else {
			print("error getting pixel buffer")
		}
	}
 */
	
}






/*
extension FourCharCode: ExpressibleByStringLiteral {
	
	public init(stringLiteral value: StringLiteralType) {
		var code: FourCharCode = 0
		// Value has to consist of 4 printable ASCII characters, e.g. '420v'.
		// Note: This implementation does not enforce printable range (32-126)
		if value.count == 4 && value.utf8.count == 4 {
			for byte in value.utf8 {
				code = code << 8 + FourCharCode(byte)
			}
		}
		else {
			print("FourCharCode: Can't initialize with '\(value)', only printable ASCII allowed. Setting to '????'.")
			code = 0x3F3F3F3F // = '????'
		}
		self = code
	}
	
	public init(extendedGraphemeClusterLiteral value: String) {
		self = FourCharCode(stringLiteral: value)
	}
	
	public init(unicodeScalarLiteral value: String) {
		self = FourCharCode(stringLiteral: value)
	}
	
	public init(_ value: String) {
		self = FourCharCode(stringLiteral: value)
	}
	
	public var string: String? {
		let cString: [CChar] = [
			CChar(self >> 24 & 0xFF),
			CChar(self >> 16 & 0xFF),
			CChar(self >> 8 & 0xFF),
			CChar(self & 0xFF),
			0
		]
		return String(cString: cString)
	}
}
*/
public extension CMIOObjectPropertyAddress {
	init(_ selector: CMIOObjectPropertySelector,
		 _ scope: CMIOObjectPropertyScope = .anyScope,
		 _ element: CMIOObjectPropertyElement = .anyElement) {
		self.init(mSelector: selector, mScope: scope, mElement: element)
	}
}

public extension CMIOObjectPropertyScope {
	/// The CMIOObjectPropertyScope for properties that apply to the object as a whole.
	/// All CMIOObjects have a global scope and for some it is their only scope.
	static let global = CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal)
	
	/// The wildcard value for CMIOObjectPropertyScopes.
	static let anyScope = CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard)
	
	/// The CMIOObjectPropertyScope for properties that apply to the input signal paths of the CMIODevice.
	static let deviceInput = CMIOObjectPropertyScope(kCMIODevicePropertyScopeInput)
	
	/// The CMIOObjectPropertyScope for properties that apply to the output signal paths of the CMIODevice.
	static let deviceOutput = CMIOObjectPropertyScope(kCMIODevicePropertyScopeOutput)
	
	/// The CMIOObjectPropertyScope for properties that apply to the play through signal paths of the CMIODevice.
	static let devicePlayThrough = CMIOObjectPropertyScope(kCMIODevicePropertyScopePlayThrough)
}

public extension CMIOObjectPropertyElement {
	/// The CMIOObjectPropertyElement value for properties that apply to the master element or to the entire scope.
	//static let master = CMIOObjectPropertyElement(kCMIOObjectPropertyElementMaster)
	static let main = CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
	/// The wildcard value for CMIOObjectPropertyElements.
	static let anyElement = CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard)
}


