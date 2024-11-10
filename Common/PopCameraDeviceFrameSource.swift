import CoreMediaIO
import Cocoa
import PopCameraDevice
import Accelerate


func Range(_ min:Double,_ max:Double,_ value:Double) -> Double
{
	return (value-min)/(max-min)
}

func NormalToRainbowf(_ hue:Double) -> (Double,Double,Double)
{
	var Normal = hue
	
	if ( Normal < 0 || Normal > 1 )
	{
		return (0,0,0)
	}
	
	//	same as NormalToRedGreenBluePurple
	if ( Normal < 1/6 )
	{
		//	red to yellow
		Normal = Range( 0/6, 1/6, Normal );
		return (1, Normal, 0)
	}
	else if ( Normal < 2/6 )
	{
		//	yellow to green
		Normal = Range( 1/6, 2/6, Normal );
		return (1-Normal, 1, 0)
	}
	else if ( Normal < 3/6 )
	{
		//	green to cyan
		Normal = Range( 2/6, 3/6, Normal );
		return (0, 1, Normal)
	}
	else if ( Normal < 4/6 )
	{
		//	cyan to blue
		Normal = Range( 3/6, 4/6, Normal );
		return (0, 1-Normal, 1)
	}
	else if ( Normal < 5/6 )
	{
		//	blue to pink
		Normal = Range( 4/6, 5/6, Normal );
		return (Normal, 0, 1)
	}
	else //if ( Normal < 5/6 )
	{
		//	pink to red
		Normal = Range( 5/6, 6/6, Normal )
		return (1, 0, 1-Normal)
	}
}

func NormalToRainbow(Normal:Double) -> (UInt8,UInt8,UInt8)
{
	let (rf,gf,bf) = NormalToRainbowf(Normal)
	let r = UInt8(rf * 255.0)
	let g = UInt8(gf * 255.0)
	let b = UInt8(bf * 255.0)
	return (r,g,b)
}



class PoolManager
{
	var pool: CVPixelBufferPool!
	var poolAttributes : NSDictionary!
	let maxPoolSize = 10
	var format : PopCameraDevice.StreamImageFormat

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
		poolAttributes = [kCVPixelBufferPoolAllocationThresholdKey: maxPoolSize]
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
	
	//	current pool, which may get reallocated as output sizes change
	var bufferPool : PoolManager?
	
	//	render contents
	//	externally set text
	var warningText : String?
	var deviceSerial : String

	public var depthParams = DepthParams()
	
	init(deviceSerial:String)
	{
		self.deviceSerial = deviceSerial
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
		//	loop until a new frame comes
		while ( true )
		{
			do
			{
				if let frame = try await PopNextFramePixels()
				{
					return frame
				}
			}
			catch let Error
			{
				return try GetDebugFrame( text:Error.localizedDescription )
				throw Error
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
				try await Task.sleep(for: .seconds(1) )
			}
				
			//	this throws if the task is cancelled
			try await Task.sleep(for: .milliseconds(1) )
			continue
		}
	}
	
	func GetDebugFrame(text:String) throws -> Frame
	{
		//	do we need to resize our data
		let DebugFormat = StreamImageFormat( width: 640, height: 480, pixelFormat: kCVPixelFormatType_32BGRA)
		let pixelBuffer = try AllocateBuffer(format: DebugFormat)
		
		//	write into the buffer
		CVPixelBufferLockBaseAddress(pixelBuffer, [])
		RenderText(pixelBuffer, text:text, backgroundColour: NSColor.blue.cgColor)
		CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
		
		//	written to buffer, now return it
		//	todo: get tmestamp from meta
		let timestamp = CMClockGetTime(CMClockGetHostTimeClock())
		let pixelFormat = DebugFormat.GetFormatDescripton()
		let frame = Frame(dimensions: (640,480), pixels: pixelBuffer, format: pixelFormat, time: timestamp)
		return frame
	}

	
	func PopNextFramePixels() async throws -> Frame?
	{
		if deviceInstance == nil
		{
			let options : [AnyHashable:Any] = [
				//"Format":"Yuv_8_88"
				//"Format":"RGB^1280x1024@30"
				"Format":"RGB",
				"DepthFormat":"Depth16mm"
			]
			self.deviceInstance = PopCameraDeviceInstance(serial:deviceSerial,options:options)
		}
		guard let deviceInstance else
		{
			return nil
		}
		
		var NextFrame = try deviceInstance.PopNextFrame()
		
		let DepthOnly = true
		
		//	skip non-depth
		while true
		{
			guard let Plane0 = NextFrame?.Meta.Planes?[0] else
			{
				break
			}
			//	is/not depth
			let ExpectedChannels = DepthOnly ? 1 : 3
			if ( Plane0.Channels == ExpectedChannels )
			{
				break
			}
			
			NextFrame = try deviceInstance.PopNextFrame()
		}
		
		guard let NextFrame else {	return nil }
		let NextFrameMeta = NextFrame.Meta
		
		if let error = NextFrameMeta.Error
		{
			throw RuntimeError( error )
		}
		
		guard let planes = NextFrameMeta.Planes else
		{
			throw RuntimeError("Frame missing planes")
		}
		
		//	do we need to resize our data
		guard let pixelBuffer = try AllocateBuffer(planes:planes)
				else
		{
			throw RuntimeError("Failed to allocate buffer for new frame")
		}
		
		guard let pixelData = NextFrame.PixelData else
		{
			throw RuntimeError("Popped frame but no pixels")
		}

		let Plane0 = planes[0]
		let planeMeta = try ImageMeta( width:UInt32(Plane0.Width), height:UInt32(Plane0.Height), imageFormat:ConvertorImageFormat(Plane0.Format) )

		let rgba8Format = try StreamImageFormat(width: planeMeta.width, height: planeMeta.height, pixelFormat: ConvertorImageFormat.bgra8.GetCoreMediaTextureFormat())
		
		var rgba8PixelsData = Data()
		
		try await WebGpuConvertImageFormat.Convert(meta:planeMeta,data:pixelData,outputFormat:.bgra8,depthParams: depthParams)
		{
			rgba8Pixels in
			
			//	doing a redundant copy - hopefully we can get rid of .originalPixels soon
			rgba8PixelsData = Data(rgba8Pixels)
			
			//	write into the output buffer
			CVPixelBufferLockBaseAddress(pixelBuffer, [])
			
			let destData = CVPixelBufferGetBaseAddress(pixelBuffer)
			let destDataSize = CVPixelBufferGetDataSize(pixelBuffer)
			try rgba8PixelsData.withUnsafeBytes
			{
				rgba8PixelsPtr in
				destData?.copyMemory(from: rgba8PixelsPtr, byteCount: rgba8Pixels.count)
			}
			CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
		}
		
		//	written to buffer, now return it
		//	todo: get tmestamp from meta
		let timestamp = CMClockGetTime(CMClockGetHostTimeClock())
		let pixelFormat = try planes[0].GetStreamImageFormat().GetFormatDescripton()
		let dimensions = (planeMeta.width,planeMeta.height)
		var frame = Frame(dimensions: dimensions, pixels: pixelBuffer, format: pixelFormat, time: timestamp)
		frame.originalPixels = rgba8PixelsData
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
	
	
	func RenderText(_ pixelBuffer:CVPixelBuffer,text:String,backgroundColour:CGColor)
	{
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

