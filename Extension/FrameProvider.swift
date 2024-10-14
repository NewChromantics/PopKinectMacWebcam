import CoreMediaIO
import Cocoa


struct Frame
{
	public var pixels : CVPixelBuffer
	public var format : CMFormatDescription
	public var time : CMTime
}

protocol FrameSource
{
	func PopNewFrame() async throws -> Frame;
	var videoFormat : CMFormatDescription! { get }
	var maxFrameDuration : CMTime { get }
	
	//	not the best approach atm, but until we do some dumb
	//	render-text to the parent, have the ability to set some external text
	var warningText : String? { get set }
}


class DebugFrameSource : FrameSource
{
	var bufferPool: CVPixelBufferPool!
	var bufferAuxAttributes: NSDictionary!
	let width : Int32 = 640
	let height : Int32 = 480
	let frameRate = 60
	let pixelFormat = kCVPixelFormatType_32BGRA
	var videoFormat : CMFormatDescription!
	var maxFrameDuration : CMTime
	{
		CMTime(value: 1, timescale: Int32(60))
	}
	
	//	render contents
	//	externally set text
	var warningText : String? = nil
	var clearColor : CGColor = NSColor.black.cgColor
	let paragraphStyle = NSMutableParagraphStyle()
	var textFontAttributes: [NSAttributedString.Key : Any]
	let textColor = NSColor.white
	let fontSize = 24.0
	var textFont : NSFont { NSFont.systemFont(ofSize: fontSize)}

	
	init(clearColour:CGColor)
	{
		self.clearColor = clearColour
		//let dims = CMVideoDimensions(width: 1920, height: 1080)
		let dims = CMVideoDimensions(width: self.width, height: self.height)
		CMVideoFormatDescriptionCreate(
			allocator: kCFAllocatorDefault,
			codecType: pixelFormat,
			//codecType: kCVPixelFormatType_32ARGB/*kCVPixelFormatType_32BGRA*/,
			width: self.width, height: self.height, extensions: nil, formatDescriptionOut: &videoFormat)
		
		let pixelBufferAttributes: NSDictionary = [
			kCVPixelBufferWidthKey: dims.width,
			kCVPixelBufferHeightKey: dims.height,
			kCVPixelBufferPixelFormatTypeKey: videoFormat.mediaSubType,
			kCVPixelBufferIOSurfacePropertiesKey: [:]
		]
		CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, pixelBufferAttributes, &bufferPool )
		bufferAuxAttributes = [kCVPixelBufferPoolAllocationThresholdKey: 5]

		paragraphStyle.alignment = NSTextAlignment.center
		textFontAttributes = [:]
		
		textFontAttributes = [
			NSAttributedString.Key.font: textFont,
			NSAttributedString.Key.foregroundColor: textColor,
			NSAttributedString.Key.paragraphStyle: paragraphStyle
		]
		
	}
	
	func PopNewFrame() async throws -> Frame
	{
		//	built in throttle for debug
		let DelayMs = 1000 / Double(frameRate)
		try await Task.sleep(for:.milliseconds(DelayMs))
		
		var pixelBufferMaybe: CVPixelBuffer?
		let timestamp = CMClockGetTime(CMClockGetHostTimeClock())
		
		let err: OSStatus = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, self.bufferPool, self.bufferAuxAttributes, &pixelBufferMaybe)
		if err != 0 || pixelBufferMaybe == nil
		{
			throw RuntimeError("Failed to allocate pixel buffer \(err)")
		}
		
		let pixelBuffer = pixelBufferMaybe!
		
		//	lock pixels & draw
		CVPixelBufferLockBaseAddress(pixelBuffer, [])
		RenderFrame(pixelBuffer,timestamp:timestamp)
		CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
		
		var frame = Frame(pixels: pixelBuffer, format: self.videoFormat, time: timestamp)
		
		return frame
	}
	
	func GetRenderText(frameTime:CMTime) -> String
	{
		var displayMessage = "Hello"
		var text = self.warningText ?? displayMessage
		text = text + " \(Int(frameTime.seconds*1000))"
		return text
	}
	
	
	func RenderFrame(_ pixelBuffer:CVPixelBuffer,timestamp:CMTime)
	{
		var text = GetRenderText( frameTime: timestamp )
		
		let pixelData = CVPixelBufferGetBaseAddress(pixelBuffer)
		let width = CVPixelBufferGetWidth(pixelBuffer)
		let height = CVPixelBufferGetHeight(pixelBuffer)
		let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
		if let context = CGContext(data: pixelData,
								   width: width,
								   height: height,
								   bitsPerComponent: 8,
								   bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
								   space: rgbColorSpace,
								   //bitmapInfo: UInt32(CGImageAlphaInfo.noneSkipFirst.rawValue) | UInt32(CGImageByteOrderInfo.order32Little.rawValue))
								   bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
		{
			
			let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
			NSGraphicsContext.saveGraphicsState()
			NSGraphicsContext.current = graphicsContext
			let cgContext = graphicsContext.cgContext
			let dstRect = CGRect(x: 0, y: 0, width: width, height: height)
			cgContext.clear(dstRect)
			cgContext.setFillColor(clearColor)
			cgContext.fill(dstRect)
			let textOrigin = CGPoint(x: 0, y: -height/2 + Int(fontSize/2.0))
			let rect = CGRect(origin: textOrigin, size: NSSize(width: width, height: height))
			text.draw(in: rect, withAttributes: self.textFontAttributes)
			NSGraphicsContext.restoreGraphicsState()
		}
	}
}

