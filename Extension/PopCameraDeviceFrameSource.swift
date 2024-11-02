import CoreMediaIO
import Cocoa
import PopCameraDevice



class PoolManager
{
	var pool: CVPixelBufferPool!
	var poolAttributes : NSDictionary!
	private var format : PopCameraDevice.StreamImageFormat

	init(format:PopCameraDevice.StreamImageFormat)
	{
		self.format = format

		let FormatDescription = self.format.GetFormatDescripton()
		let pixelBufferAttributes: NSDictionary =
		[
			kCVPixelBufferWidthKey: self.format.width,
			kCVPixelBufferHeightKey: self.format.height,
			kCVPixelBufferPixelFormatTypeKey: FormatDescription.mediaSubType,
			kCVPixelBufferIOSurfacePropertiesKey: [:]
		]
		CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, pixelBufferAttributes, &pool )
		poolAttributes = [kCVPixelBufferPoolAllocationThresholdKey: 5]
	}
	
	func isMatchingFormat(_ matchFormat:PopCameraDevice.StreamImageFormat) -> Bool
	{
		return format.width == matchFormat.width && format.height == matchFormat.height && format.pixelFormat == matchFormat.pixelFormat
	}
	
	func AllocateBuffer() throws -> CVPixelBuffer
	{
		var pixelBufferMaybe: CVPixelBuffer?
		let error : OSStatus = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, self.pool, self.poolAttributes, &pixelBufferMaybe)
		if error != 0 || pixelBufferMaybe == nil
		{
			throw RuntimeError("Failed to allocate pixel buffer from pool \(error)")
		}
		
		let pixelBuffer = pixelBufferMaybe!
		return pixelBuffer
	}
}

class PopCameraDeviceFrameSource : FrameSource
{
	//	device, we will re-create this on error and try to keep it alive
	var deviceInstance : PopCameraDeviceInstance? = nil
	
	var bufferPool : PoolManager?
	/*
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
	 */
	
	//	render contents
	//	externally set text
	var warningText : String?
	var deviceSerial : String
	
	var ShownWelcomeFrame : Bool = false
	/*
	 var clearColor : CGColor = NSColor.black.cgColor
	 let paragraphStyle = NSMutableParagraphStyle()
	 var textFontAttributes: [NSAttributedString.Key : Any]
	 let textColor = NSColor.white
	 let fontSize = 24.0
	 var textFont : NSFont { NSFont.systemFont(ofSize: fontSize)}
	 */
	
	init(deviceSerial:String)
	{
		//self.clearColor = NSColor.cyan.cgColor
		self.deviceSerial = deviceSerial
		
		/*
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
		 */
	}
	
	deinit
	{
		Free()
	}
	
	func Free()
	{
		if let deviceInstance
		{
			deviceInstance.Free()
			self.deviceInstance = nil
		}
	}
	
	func PopNewFrame() async throws -> Frame
	{
		if !ShownWelcomeFrame
		{
			ShownWelcomeFrame = true
			return try GetDebugFrame( text:"Waiting for first frame..." )
		}

		//	loop until a new frame comes
		while ( true )
		{
			do
			{
				if let frame = try PopNextFramePixels()
				{
					return frame
				}
			}
			catch let Error
			{
				return try GetDebugFrame( text:Error.localizedDescription )
			}
			
			//	if there's a warning, show it
			if let warningText
			{
				do
				{
					return try GetDebugFrame( text:warningText )
				}
				catch let Error
				{
					print(Error)
				}
			}
				
			try! await Task.sleep(for: .seconds(1) )
			continue
		}
	}
	
	func GetDebugFrame(text:String) throws -> Frame
	{
		//	do we need to resize our data
		let DebugFormat = StreamImageFormat( width: 640, height: 480, pixelFormat: kCVPixelFormatType_32BGRA)
		let pixelBuffer = try AllocateBuffer(format: DebugFormat)
		
		//	write into the buffer
		do
		{
			//	lock pixels...
			CVPixelBufferLockBaseAddress(pixelBuffer, [])
			
			//	pop frame into our buffer
			RenderFrame(pixelBuffer, text:text, backgroundColour: NSColor.blue.cgColor)
			//RenderFrame(pixelBuffer,timestamp:timestamp)
			
			CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
		}
		catch let error
		{
			ReleaseBuffer(pixelBuffer)
			throw error
		}
		
		//	written to buffer, now return it
		//	todo: get tmestamp from meta
		let timestamp = CMClockGetTime(CMClockGetHostTimeClock())
		let pixelFormat = DebugFormat.GetFormatDescripton()
		let frame = Frame(pixels: pixelBuffer, format: pixelFormat, time: timestamp)
		return frame
	}

	
	func PopNextFramePixels() throws -> Frame?
	{
		if deviceInstance == nil
		{
			self.deviceInstance = PopCameraDeviceInstance(serial:deviceSerial)
		}
		guard let deviceInstance else
		{
			return nil
		}
		
		let NextFrame = try deviceInstance.PopNextFrame()
		guard let NextFrame else {	return nil }
		let NextFrameMeta = NextFrame.Meta
		
		if let error = NextFrameMeta.Error
		{
			throw RuntimeError( error )
		}
		
		guard let Planes = NextFrameMeta.Planes else
		{
			throw RuntimeError("Frame missing planes")
		}
		
		//	do we need to resize our data
		guard let pixelBuffer = try AllocateBuffer(planes:Planes)
				else
		{
			throw RuntimeError("Failed to allocate buffer for new frame")
		}
		
		//	write into the buffer
		do
		{
			//	lock pixels...
			CVPixelBufferLockBaseAddress(pixelBuffer, [])

			//	copy frame pixels in
			//RenderFrame(pixelBuffer, text:"todo: render new frame", backgroundColour: NSColor.red.cgColor)
			//RenderFrame(pixelBuffer,timestamp:timestamp)
			
			CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
		}
		catch let error
		{
			ReleaseBuffer(pixelBuffer)
			throw error
		}

		//	written to buffer, now return it
		//	todo: get tmestamp from meta
		let timestamp = CMClockGetTime(CMClockGetHostTimeClock())
		let pixelFormat = try Planes[0].GetStreamImageFormat().GetFormatDescripton()
		let frame = Frame(pixels: pixelBuffer, format: pixelFormat, time: timestamp)
		return frame
	}
	
	func ReleaseBuffer(_ buffer:CVPixelBuffer)
	{
	}
	
	func AllocateBuffer(planes:[PlaneMeta]) throws -> CVPixelBuffer?
	{
		if planes.count == 0
		{
			throw RuntimeError("Trying to allocate pixel buffer with no planes")
		}
		
		let planeFormat = try planes[0].GetStreamImageFormat()
		return try AllocateBuffer( format:planeFormat )
	}
	
	
	func AllocateBuffer(format:StreamImageFormat) throws -> CVPixelBuffer
	{
		//	do we need to resize our pool
		//	todo: check old dimensions
		if bufferPool != nil
		{
			if !bufferPool!.isMatchingFormat(format)
			{
				bufferPool = nil
			}
		}
		if bufferPool == nil
		{
			bufferPool = PoolManager(format: format)
		}
		
		let image = try bufferPool!.AllocateBuffer()
		return image
	}
	
	
	func GetRenderText(frameTime:CMTime) -> String
	{
		let text = "\(deviceSerial)\n\(Int(frameTime.seconds*1000))"
		return text
	}
	
	
	func RenderFrame(_ pixelBuffer:CVPixelBuffer,text:String,backgroundColour:CGColor)
	{
		//	need rgba (not rgb) to write via CG (quartz)
		//pixelBuffer.co
		
		
		let pixelData = CVPixelBufferGetBaseAddress(pixelBuffer)
		let width = CVPixelBufferGetWidth(pixelBuffer)
		let height = CVPixelBufferGetHeight(pixelBuffer)
		let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
		let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
		
		if let context = CGContext(data: pixelData,
								   width: width,
								   height: height,
								   bitsPerComponent: 8,
								   bytesPerRow: bytesPerRow,
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
			cgContext.setFillColor(backgroundColour)
			cgContext.fill(dstRect)
			
			let fontSize = 42.0
			var textFont : NSFont { NSFont.systemFont(ofSize: fontSize)}
			let textColor = NSColor.white
			let paragraphStyle = NSMutableParagraphStyle()
			paragraphStyle.alignment = NSTextAlignment.center

			let textFontAttributes = [
				NSAttributedString.Key.font: textFont,
				NSAttributedString.Key.foregroundColor: textColor,
				NSAttributedString.Key.paragraphStyle: paragraphStyle
			]
			
			let textOrigin = CGPoint(x: 0, y: -height/2 + Int(fontSize/2.0))
			let rect = CGRect(origin: textOrigin, size: NSSize(width: width, height: height))
			text.draw(in: rect, withAttributes: textFontAttributes)
			NSGraphicsContext.restoreGraphicsState()
		}
	}
}

