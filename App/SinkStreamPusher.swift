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
	var sinkQueue: CMSimpleQueue?
	{
		return sinkQueuePoiner.pointee?.takeUnretainedValue()
	}
	var sinkQueuePoiner : UnsafeMutablePointer<Unmanaged<CMSimpleQueue>?>!

	var startedDeviceAndStream : (CMIOObjectID,CMIOStreamID)? = nil
	
	//	we identify the sink stream with a matching key/value
	var sinkPropertyKey : String
	var sinkPropertyValue : String

	
	init(device: AVCaptureDevice, sinkPropertyKey:String, sinkPropertyValue:String) throws
	{
		self.sinkPropertyKey = sinkPropertyKey
		self.sinkPropertyValue = sinkPropertyValue
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
		if ( sinkQueuePoiner != nil )
		{
			sinkQueuePoiner.deallocate()
			sinkQueuePoiner = nil
		}
		
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
	
	func getProperty(streamId: CMIOStreamID,key:String) -> String?
	{
		let Fourcc = FourCharCode(key)
		let selector = CMIOObjectPropertySelector(Fourcc)
		var address = CMIOObjectPropertyAddress( selector, .global, .main)
		let exists = CMIOObjectHasProperty(streamId, &address)
		if ( !exists )
		{
			return nil
		}
		
		var dataSize: UInt32 = 0
		var dataUsed: UInt32 = 0
		CMIOObjectGetPropertyDataSize(streamId, &address, 0, nil, &dataSize)
		var name: CFString = "" as NSString
		CMIOObjectGetPropertyData(streamId, &address, 0, nil, dataSize, &dataUsed, &name);
		return name as String
	}
	
	func GetSinkStreamId() throws -> CMIOStreamID
	{
		let DeviceUid = try GetCmioDeviceId(uid: device.uniqueID)
		
		let StreamIds = GetInputStreamIds(deviceId: DeviceUid)

		//	find stream with our sink property
		for StreamId in StreamIds
		{
			guard let SinkValue = getProperty(streamId: StreamId, key: sinkPropertyKey ) else
			{
				continue
			}
			
			if ( SinkValue != sinkPropertyValue )
			{
				print("Sink property(\(sinkPropertyKey) found with mismatched value: \(SinkValue) expected \(sinkPropertyValue)")
				continue
			}
			
			//	assume value is good if key present
			//print("Sink property found: \(SinkValue)")
			return StreamId
		}
		
		throw RuntimeError("No stream found with property \(sinkPropertyKey)=\(sinkPropertyValue)")
	}
	
	func BindToSinkQueue(sinkStreamId:CMIOStreamID) throws
	{
		//	allocate a pointer that we'll pass to CMIOStreamCopyBufferQueue, which will set it
		//	gr: todo: free this allocation!
		//	gr: this is 0xbebebebe with asan, or 0xaaaaa for memory scribble
		//		normally its nil
		sinkQueuePoiner = UnsafeMutablePointer<Unmanaged<CMSimpleQueue>?>.allocate(capacity: 10)
		//	gr: clear pointer in malloc scribble mode etc so an untouched pointer is detected
		sinkQueuePoiner.pointee = nil
		
		//	get pointer for callback
		// see https://stackoverflow.com/questions/53065186/crash-when-accessing-refconunsafemutablerawpointer-inside-cgeventtap-callback
		//let SelfRef = UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque())
		let SelfRef = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
		
		
		let OnQueueAltered : CMIODeviceStreamQueueAlteredProc =
		{
			(sinkStream: CMIOStreamID, buf: UnsafeMutableRawPointer?, refCon: UnsafeMutableRawPointer?) in
			
			if ( refCon == nil )
			{
				print("Queue altered nil self")
				return
			}
			
			let ThisPointer = Unmanaged<CameraWithSinkInterface>.fromOpaque(refCon!)
			let This = ThisPointer.takeUnretainedValue()
			//This.readyToEnqueue = true
		}
		
		//	this writes an address into pointerQueue
		//	gr: this copies.... TO our pointer? to get a queue for....?
		let Result = CMIOStreamCopyBufferQueue(sinkStreamId,OnQueueAltered,SelfRef,sinkQueuePoiner)
		if Result != 0
		{
			throw RuntimeError("Error \(Result) from copy buffer queue")
		}
		
		//	did it write a new queue value?
		if sinkQueuePoiner.pointee == nil
		{
			throw RuntimeError("CMIOStreamCopyBufferQueue didnt write queue pointer")
		}
		
		let deviceId = try GetCmioDeviceId(uid: device.uniqueID)
		let StartDeviceResult = CMIODeviceStartStream(deviceId, sinkStreamId)
		if StartDeviceResult != 0
		{
			throw RuntimeError("Error \(StartDeviceResult) from starting sink stream")
		}
		startedDeviceAndStream = (deviceId,sinkStreamId)
	}
	
	func Send(_ sample:CMSampleBuffer) throws
	{
		/*
		if ( self.queueAlteredCount == 0 )
		{
			print("Queue not ready")
			return
		}
		*/
		guard let queue = self.sinkQueue else
		{
			throw RuntimeError("Queue not allocated yet")
		}
		
		var QueueCount = CMSimpleQueueGetCount(queue)
		var QueueCapacity = CMSimpleQueueGetCapacity(queue)

		guard QueueCount < QueueCapacity else
		{
			//throw RuntimeError("Queue is at capacity \(QueueCount)/\(QueueCapacity)")
			print("Queue is at capacity \(QueueCount)/\(QueueCapacity)")
			return
		}
		let samplePointer = UnsafeMutableRawPointer(Unmanaged.passRetained(sample).toOpaque())
		let QueueResult = CMSimpleQueueEnqueue(queue, element: samplePointer)
		
		QueueCount = CMSimpleQueueGetCount(queue)
		QueueCapacity = CMSimpleQueueGetCapacity(queue)
		print("Queued new sample \(QueueCount)/\(QueueCapacity) result=\(QueueResult)")
	}
}


//	this class looks for a camera wth a sink stream we can push to
//	it then delivers any frames pushed in
//	dont override this, or the observable object breaks
final class SinkStreamPusher : NSObject, ObservableObject
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
	var sinkPropertyKey : String
	var sinkPropertyValue : String

	var Freed = false
	
	var DebugFrames = DebugFrameSource(displayText: "App",clearColour: NSColor.blue.cgColor)
	
	//	allow change at runtime
	var frameSource : FrameSource? = nil
	var lastFrame : Frame?
	
	var _videoDescription: CMFormatDescription!
	var _bufferPool: CVPixelBufferPool!
	var _bufferAuxAttributes: NSDictionary!

	
	init(cameraName:String,sinkPropertyKey:String,sinkPropertyValue:String,frameSource:FrameSource?=nil/*,log: @escaping (_ message:String)->()*/)
	{
		//self.logFunctor = log
		self.targetCameraName = cameraName
		self.sinkPropertyKey = sinkPropertyKey
		self.sinkPropertyValue = sinkPropertyValue
		self.frameSource = frameSource
		
		super.init()
				
		InitBufferPool()
		
		Task
		{
			try await Thread()
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
	
	
	
	func Thread() async throws
	{
		while ( !Freed )
		{
			do
			{
				threadStateString = "Looking for camera..."
				let Camera = try await FindCamera()
				threadStateString = "Got Camera, sending frame..."
				while ( !Freed )
				{
					try await SendNextFrameToStream(camera:Camera)
					//try await Task.sleep( for:.seconds(1/Double(PushFrameRate)) )
				}
			}
			catch let Error
			{
				OnError(Error.localizedDescription)
				threadStateString = "Error: \(Error.localizedDescription)"
				
				//	breath between errors
				try await Task.sleep( for:.seconds(1) )
			}
		}
	}
	
	func InitBufferPool()
	{
		let fixedCamWidth : Int32 = 123
		let fixedCamHeight : Int32 = 123
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

		return try CameraWithSinkInterface(device:Device,sinkPropertyKey: sinkPropertyKey,sinkPropertyValue:sinkPropertyValue)
	}
	
	func SendNextFrameToStream(camera:CameraWithSinkInterface) async throws
	{
		guard let frameSource else
		{
			throw RuntimeError("frame source missing")
		}
		
		let Frame = try await frameSource.PopNewFrame()
		lastFrame = Frame
		let Sample = try Frame.sampleBuffer
		
		try camera.Send(Sample)
	}
	
	func GetTestImageSampleBuffer(_ image:CGImage) async throws -> CMSampleBuffer
	{
		var pixelBuffer: CVPixelBuffer?
		let CreatePixelBufferResult = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, self._bufferPool, self._bufferAuxAttributes, &pixelBuffer)
		if ( CreatePixelBufferResult != 0 )
		{
			throw RuntimeError("Failed to create pixel buffer result=\(CreatePixelBufferResult)")
		}
		guard let pixelBuffer else
		{
			throw RuntimeError("Failed to create pixel buffer null")
		}
		
		CVPixelBufferLockBaseAddress(pixelBuffer, [])
		
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
		let CreateSampleBufferResult = CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: self._videoDescription, sampleTiming: &timingInfo, sampleBufferOut: &sbuf)
		if ( CreateSampleBufferResult != 0 )
		{
			throw RuntimeError("Failed to create sample buffer result=\(CreateSampleBufferResult)")
		}
		
		return sbuf
	}
		
	
	
	
}







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

/*
class TestSinkStreamPusher : SinkStreamPusherBase
{
	
	let showTestImageEveryXFrames = 60
	var pushedFrameCount = 0
	var testImage = NSImage(named: "TestImage")

	
	func GetSampleBuffer() async throws -> CMSampleBuffer
	{
		guard let image = testImage else
		{
			throw RuntimeError("Missing test image")
		}
		guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else
		{
			throw RuntimeError("failed to get image to send to sink")
		}
		
		let Sample = try await GetSampleBuffer(cgImage)
		return Sample
	}

	func GetSampleBuffer(_ image:CGImage) async throws -> CMSampleBuffer
	{
		pushedFrameCount += 1
		if ( pushedFrameCount % showTestImageEveryXFrames == 0 )
		{
			return try await GetTestImageSampleBuffer(image)
		}
		else
		{
			let frame = try DebugFrames.PopNewFrameSync()
			return try frame.sampleBuffer
		}
	}
}
*/
