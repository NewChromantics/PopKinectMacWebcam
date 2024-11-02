import CoreMediaIO
import Cocoa


struct Frame
{
	public var pixels : CVPixelBuffer?
	public var format : CMFormatDescription?

	public var sample : CMSampleBuffer?
	public var time : CMTime
	public var timeNanos : UInt64
	{
		return UInt64(time.seconds * Double(NSEC_PER_SEC))
	}
	
	public var sampleBuffer : CMSampleBuffer
	{
		get throws
		{
			if let sample
			{
				return sample
			}
			
			if ( pixels == nil )
			{
				throw RuntimeError("Samplebuffer and pixelbuffer are both null")
			}
			
			var sbuf: CMSampleBuffer!
			var timingInfo = CMSampleTimingInfo()
			timingInfo.presentationTimeStamp = time
			let err = CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels!, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: format!, sampleTiming: &timingInfo, sampleBufferOut: &sbuf)
			if err != 0
			{
				throw RuntimeError("Error creating sample buffer \(err)")
			}
			return sbuf
		}
	}
}

protocol FrameSource
{
	func PopNewFrame() async throws -> Frame
	func Free()
	/*
	var videoFormat : CMFormatDescription! { get }
	var maxFrameDuration : CMTime { get }
	*/
}


class DebugFrameSource : FrameSource
{
	var bufferPool: CVPixelBufferPool!
	var bufferAuxAttributes: NSDictionary!
	let width : Int32 = 1000
	let height : Int32 = 1000
	let frameRate = 60
	let pixelFormat = kCVPixelFormatType_32BGRA
	var videoFormat : CMFormatDescription!
	var maxFrameDuration : CMTime
	{
		CMTime(value: 1, timescale: Int32(60))
	}
	
	//	render contents
	//	externally set text
	var warningText : String?
	var displayText : String
	var frameCounter : Int = 0
	var clearColor : CGColor = NSColor.black.cgColor
	let paragraphStyle = NSMutableParagraphStyle()
	var textFontAttributes: [NSAttributedString.Key : Any]
	let textColor = NSColor.white
	let fontSize = 42.0
	var textFont : NSFont { NSFont.systemFont(ofSize: fontSize)}
	let PoolMaxAllocations = 13
	
	init(displayText:String,clearColour:CGColor)
	{
		self.clearColor = clearColour
		self.displayText = displayText
		
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
		bufferAuxAttributes = [kCVPixelBufferPoolAllocationThresholdKey: PoolMaxAllocations]

		paragraphStyle.alignment = NSTextAlignment.center
		textFontAttributes = [:]
		
		textFontAttributes = [
			NSAttributedString.Key.font: textFont,
			NSAttributedString.Key.foregroundColor: textColor,
			NSAttributedString.Key.paragraphStyle: paragraphStyle
		]
		
	}
	
	func Free()
	{
	}
	
	func PopNewFrame() async throws -> Frame
	{
		//	built in throttle for debug
		let DelayMs = 1000 / Double(frameRate)
		try await Task.sleep(for:.milliseconds(DelayMs))
		
		return try PopNewFrameSync()
	}
	
	func PopNewFrameSync() throws -> Frame
	{
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
		
		let frame = Frame(pixels: pixelBuffer, format: self.videoFormat, time: timestamp)
		
		frameCounter = frameCounter+1
		
		return frame
	}
	
	func GetRenderText(frameTime:CMTime) -> String
	{
		let text = "\(displayText)\n\(Int(frameTime.seconds*1000))\n\(frameCounter)"
		return text
	}
	
	
	func RenderFrame(_ pixelBuffer:CVPixelBuffer,timestamp:CMTime)
	{
		let text = GetRenderText( frameTime: timestamp )
		
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

