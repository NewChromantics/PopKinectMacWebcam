import SwiftUI
import WebGPU
import CoreMedia

struct DepthParams
{
	var depthClipNear = UInt32(10)
	var depthClipFar = UInt32(15000)
	//let depthMin = UInt32(1)	//	0 is invalid
	//let depthMax = UInt32(4095)	//	11bit range 0xfff
}


let ConvertImageKernelSource = """
struct DepthParams {
 depthClipNear : u32,	//	100
 depthClipFar : u32,	//	15000
}

  //	no byte access, so access is 32 bit and we need to work around that
  @group(0) @binding(0) var<storage, read> inputRgb8 : array<u32>;
  @group(0) @binding(1) var<storage, read_write> outputBgra8 : array<u32>;
  @group(0) @binding(2) var<uniform> depthParams : DepthParams;
  

  fn GetInput8Value(index:u32) -> u32
  {
   let chunkIndex = index / 4;
   let chunk = inputRgb8[chunkIndex];
   let chunkByteIndex = index % 4;
   let byte = chunk >> (chunkByteIndex*8);
   return byte & 0xff;
  }
  
  fn GetInput16Value(index:u32) -> u32
  {
   let chunkIndex = index / 2;
   let chunk = inputRgb8[chunkIndex];
   let chunkByteIndex = index % 2;
   let byte = chunk >> (chunkByteIndex*16);
   return byte & 0xffff;
  }
  
  fn GetInputRgbBytes(pixelIndex:u32) -> vec3<u32>
  {
   let rgbChannelCount : u32 = 3;
   let InputIndex = pixelIndex * rgbChannelCount;
   let r = GetInput8Value(InputIndex+0);
   let g = GetInput8Value(InputIndex+1);
   let b = GetInput8Value(InputIndex+2);
   return vec3<u32>( r, g, b );
  }
  
  fn GetInputDepth16(pixelIndex:u32) -> u32
  {
   return GetInput16Value(pixelIndex);
  }
  
  fn GetBgra32(red:u32,green:u32,blue:u32,alpha:u32) -> u32
  {
   let bgra32 = (blue<<0) | (green<<8) | (red<<16) | (alpha<<24);
   return u32(bgra32);
  }
  
  fn Range32(min:u32,max:u32,value:u32) -> f32
  {
   return ( f32(value-min) / f32(max-min) );
  }
  
  fn Rangef(min:f32,max:f32,value:f32) -> f32
  {
   return ( f32(value-min) / f32(max-min) );
  }
  
  fn NormalToRgbf(normal:f32) -> vec3<f32>
  {
   var Normal = normal;
   let blocks = 4.0;	//	ry yg gc cb
   if ( Normal < 0 )
   {
    return vec3(0,0,1);
   }
   else if ( Normal < 1.0/blocks )
   {
	//	red to yellow
	Normal = Rangef( 0/blocks, 1/blocks, Normal );
	return vec3(1, Normal, 0);
   }
   else if ( Normal < 2/blocks )
   {
	//	yellow to green
	Normal = Rangef( 1/blocks, 2/blocks, Normal );
	return vec3(1-Normal, 1, 0);
   }
   else if ( Normal < 3/blocks )
   {
    //	green to cyan
    Normal = Rangef( 2/blocks, 3/blocks, Normal );
    return vec3(0, 1, Normal);
   }
   else if ( Normal < 4/blocks )
   {
    //	cyan to blue
    Normal = Rangef( 3/blocks, 4/blocks, Normal );
    return vec3(0, 1-Normal, 1);
   }
   else // > blocks/blocks (1)
   {
    return vec3(0,0,0);
   }
  }
  
  fn NormalToRgb(normal:f32) -> vec3<u32>
  {
   let rgbf = NormalToRgbf(normal) * vec3<f32>(255,255,255);
   return vec3( u32(rgbf.x), u32(rgbf.y), u32(rgbf.z) );
  }
  
  @compute @workgroup_size(1,1,1) fn convert_rgb8_to_bgra8(
   @builtin(workgroup_id) workgroup_id : vec3<u32>,
   @builtin(local_invocation_id) local_invocation_id : vec3<u32>,
   @builtin(global_invocation_id) global_invocation_id : vec3<u32>,
   @builtin(local_invocation_index) local_invocation_index: u32,
   @builtin(num_workgroups) num_workgroups: vec3<u32>
  )
  {
   let width = num_workgroups.x;
   let height = num_workgroups.y;
   let x = workgroup_id.x;
   let y = workgroup_id.y;
   let pixelIndex = (y * width) + x;
  
   //	input is 32bit aligned, so we need to read individual parts
   let rgb = GetInputRgbBytes(pixelIndex);
   let bgra32 = GetBgra32( rgb.x, rgb.y, rgb.z, 255 );
   outputBgra8[pixelIndex] = bgra32;
  }
  
  @compute @workgroup_size(1,1,1) fn convert_depth16mm_to_bgra8(
   @builtin(workgroup_id) workgroup_id : vec3<u32>,
   @builtin(local_invocation_id) local_invocation_id : vec3<u32>,
   @builtin(global_invocation_id) global_invocation_id : vec3<u32>,
   @builtin(local_invocation_index) local_invocation_index: u32,
   @builtin(num_workgroups) num_workgroups: vec3<u32>
  )
  {
   let width = num_workgroups.x;
   let height = num_workgroups.y;
   let x = workgroup_id.x;
   let y = workgroup_id.y;
   let pixelIndex = (y * width) + x;
  
   //	input is 32bit aligned, so we need to read individual parts
   let depth16 = GetInputDepth16(pixelIndex);
   var depthf = Range32( depthParams.depthClipNear, depthParams.depthClipFar, depth16 );
   //depthf = Range32( 0, width, x );
   let rgb = NormalToRgb(depthf);
   let valid = ( depthf >= 0.0 && depthf <= 1.0); 
   var alpha : u32 = 255;
   if ( !valid )
   {
    alpha = 0;
   }
   let bgra32 = GetBgra32( rgb.x, rgb.y, rgb.z, alpha );
   outputBgra8[pixelIndex] = u32(bgra32);
  }
"""

enum ConvertorImageFormat
{
	case rgb8
	case bgra8
	case depth16mm
	
	init(_ name:String) throws
	{
		switch name
		{
			case "RGB":			self = .rgb8
			case "BGRA":		self = .bgra8
			case "Depth16mm":	self = .depth16mm
			default:	throw RuntimeError("Unknown image format name \(name)")
		}
	}
	
	//	will throw for unhandled or unconvertible types
	func GetWebGpuTextureFormat() throws -> TextureFormat
	{
		switch self
		{
			case .rgb8:		throw RuntimeError("rgb8 has no TextureFormat equivilent")
			case .bgra8:	return TextureFormat.bgra8Unorm
			default: throw RuntimeError("unhandled ConvertorImageFormat \(self)")
		}
	}
	
	//	will throw for unhandled or unconvertible types
	func GetCoreMediaTextureFormat() throws -> CMPixelFormatType
	{
		switch self
		{
			case .rgb8:		return kCMPixelFormat_24RGB
			case .bgra8:	return kCMPixelFormat_32BGRA
			default: throw RuntimeError("unhandled ConvertorImageFormat \(self)")
		}
	}
	
	var channelCount : UInt32
	{
		switch self
		{
			case .rgb8:			return 3
			case .bgra8:		return 4
			case .depth16mm:	return 1
		}
	}
	
	var channelByteSize : UInt32
	{
		switch self
		{
			case .rgb8:			return 1
			case .bgra8:		return 1
			case .depth16mm:	return 2
		}
	}
}

public struct ImageMeta : Equatable
{
	var width : UInt32
	var height : UInt32
	var bytesPerRow : UInt32
	{
		get throws
		{
			return try width * channels
		}
	}
	var extent : Extent3d
	{
		return Extent3d(width: width,height: height)
	}
	var imageFormat : ConvertorImageFormat
	var textureFormat : TextureFormat
	{
		get throws
		{
			return try imageFormat.GetWebGpuTextureFormat()
		}
	}
	
	var channels : UInt32 {	return try imageFormat.channelCount	}
	var channelByteSize : UInt32	{	return try imageFormat.channelByteSize	}
	
	var byteSize : UInt64
	{
		get throws
		{
			return try (UInt64(channels * channelByteSize * width * height))
		}
	}
}

class WebGpuConvertImageFormat
{
	//	input as buffer
	var inputBuffer : Buffer
	var inputMeta : ImageMeta
	var outputBuffer : Buffer
	var outputMappable : Buffer	//	to read pixels, need a mappable type, which is incompatible with the storage
	var outputMeta : ImageMeta
	var depthParams : DepthParams
	var depthParamsBuffer : Buffer
	
	var outputBufferCopyMeta : ImageCopyBuffer
	{
		get throws
		{
			let layout = try TextureDataLayout(offset: 0,bytesPerRow: outputMeta.bytesPerRow)
			return ImageCopyBuffer(layout: layout, buffer: outputBuffer)
		}
	}
	
	init(device:WebGPU.Device,inputMeta:ImageMeta,outputMeta:ImageMeta,depthParams:DepthParams=DepthParams()) throws
	{
		self.depthParams = depthParams
		
		//	todo: this needs to be aligned to 32(in total) - do we need to pad, or will webgpu pad it?
		let inputByteSize = try inputMeta.byteSize
		let inputUsage = BufferUsage(rawValue: BufferUsage.storage.rawValue | BufferUsage.copyDst.rawValue )
		let inputBufferDescription = BufferDescriptor(label: "convertImageInput", usage:inputUsage, size: inputByteSize )
		self.inputBuffer = device.createBuffer(descriptor: inputBufferDescription)
		self.inputMeta = inputMeta

		let outputByteSize = try outputMeta.byteSize
		let outputUsage = BufferUsage(rawValue: BufferUsage.storage.rawValue | BufferUsage.copySrc.rawValue )
		let outputBufferDescription = BufferDescriptor(label: "convertImageOutput", usage:outputUsage, size: outputByteSize )
		self.outputBuffer = device.createBuffer(descriptor: outputBufferDescription)
		self.outputMeta = outputMeta

		let outputMappableUsage = BufferUsage(rawValue: BufferUsage.mapRead.rawValue | BufferUsage.copyDst.rawValue )
		let outputMappableDescription = BufferDescriptor(label: "convertImageOutputMappable", usage:outputMappableUsage, size: outputByteSize )
		self.outputMappable = device.createBuffer(descriptor: outputMappableDescription)
		
		self.depthParamsBuffer = withUnsafeBytes(of: depthParams)
		{
			bytes in
			let buffer = device.createBuffer(descriptor: BufferDescriptor(
				usage: .uniform,
				size: UInt64(bytes.count),
				mappedAtCreation: true))
			buffer.getMappedRange().copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
			buffer.unmap()
			return buffer
		}
	}
	
	var kernelEntryName : String
	{
		return "convert_\(inputMeta.imageFormat)_to_\(outputMeta.imageFormat)"
	}
			
	//	put new data into the input buffer
	//	func writeData
	
	func AddConvertPass(inputData:[UInt8],device:Device,encoder:CommandEncoder)
	{
		inputData.withUnsafeBytes
		{
			inputBytes in
			device.queue.writeBuffer( inputBuffer, bufferOffset: 0, data: inputBytes)
		}

		let computeMeta = ComputePassDescriptor(label: "Convert Image")
		let pass = encoder.beginComputePass(descriptor: computeMeta)
		
		let bindGroupLayout = device.createBindGroupLayout(descriptor: BindGroupLayoutDescriptor(
			entries: [
				BindGroupLayoutEntry(binding: 0,visibility:.compute, buffer: BufferBindingLayout(type:.readOnlyStorage) ),
				BindGroupLayoutEntry(binding: 1,visibility:.compute, buffer: BufferBindingLayout(type:.storage) ),
				BindGroupLayoutEntry(binding: 2,visibility:.compute, buffer: BufferBindingLayout(type:.uniform) ),
			]
		))
		
		let pipelineLayout = device.createPipelineLayout(descriptor: PipelineLayoutDescriptor(
			bindGroupLayouts: [bindGroupLayout])
		)
		
		//let kernelName = "convert_rgb8_to_bgra8"
		let kernelName = kernelEntryName
		let kernelSource = ShaderSourceWgsl(code:ConvertImageKernelSource)
		let kernelMeta = ShaderModuleDescriptor(label:"Convert Kernel",nextInChain: kernelSource)
		let kernelModule = device.createShaderModule(descriptor: kernelMeta)
		let kernelStage = ProgrammableStageDescriptor(module: kernelModule, entryPoint: kernelName)
		
		let pipelineDescription = ComputePipelineDescriptor(
			label: "ConvertImagePipeline \(kernelName)",
			layout: pipelineLayout,
			compute: kernelStage
		)
		let pipeline = device.createComputePipeline(descriptor:pipelineDescription)
		
		let inputRgb8 = self.inputBuffer
		let outputBgra8 = self.outputBuffer

		let bindMeta = BindGroupDescriptor(label: "Buffer Bind",
										   layout: pipeline.getBindGroupLayout(groupIndex:0),
										   entries: [
											BindGroupEntry( binding: 0, buffer: inputRgb8 ),
											BindGroupEntry( binding: 1, buffer: outputBgra8 ),
											BindGroupEntry( binding: 2, buffer: depthParamsBuffer ),
										   ]
		)
		
		let bindGroup = device.createBindGroup(descriptor: bindMeta)
		
		pass.setPipeline(pipeline)
		pass.setBindGroup(groupIndex: 0,group: bindGroup)
		let width = inputMeta.width
		let height = inputMeta.height
		let depth = UInt32(1)
		pass.dispatchWorkgroups(workgroupcountx: width,workgroupcounty: height,workgroupcountz: depth)
		pass.end()
		
	}
}


func somecallback(x:BufferMapAsyncStatus) -> Void
{
}

//	handy "do it all in one go" api
extension WebGpuConvertImageFormat
{
	static let gpu = WebGPU.WebGpuRenderer()
	
	static func Convert(meta:ImageMeta,data:Data,outputFormat:ConvertorImageFormat) async throws -> Data
	{
		var outputData = Data()
		try await Convert(meta:meta, data: data, outputFormat: outputFormat)
		{
			outputBufferView8Ptr in
			outputData = Data(outputBufferView8Ptr)
		}
		return outputData
	}
	
	static func Convert(meta:ImageMeta,data:Data,outputFormat:ConvertorImageFormat,depthParams:DepthParams=DepthParams(),onGotOutput:(UnsafeBufferPointer<UInt8>)throws->Void) async throws
	{
		let outputMeta = ImageMeta(width: meta.width, height: meta.height, imageFormat: outputFormat)
		//	todo: make an async gpu.WaitForDevice()
		let device = try await gpu.waitForDevice()
		let convertor = try WebGpuConvertImageFormat( device:device, inputMeta: meta, outputMeta: outputMeta, depthParams:depthParams )
		
		//	start a gpu run
		let encoder = device.createCommandEncoder()
		
		let dataBytes = [UInt8](data)
		convertor.AddConvertPass(inputData: dataBytes, device: device, encoder:encoder)
		
		//	need to copy to a mappable buffer so we can read it on cpu
		let outputByteSize = convertor.outputBuffer.size
		encoder.copyBufferToBuffer(source: convertor.outputBuffer, sourceOffset: 0, destination: convertor.outputMappable, destinationOffset: 0, size: outputByteSize)
		
		let commandBuffer = encoder.finish()
		
		device.queue.submit(commands: [commandBuffer])
	
		//	read back output buffer to cpu
		//	gr: when this fails, doesnt seem to error properly, but look in console for errors!
		let readBuffer = convertor.outputMappable
	
		
		var IsFinished = false
		while ( !IsFinished )
		{
			var callback : (BufferMapAsyncStatus) -> Void =
			{
				status in
				print("Status \(status)")
				IsFinished = status == .success
			}

			try readBuffer.mapAsync(mode: .read, offset: 0, size: Int(outputByteSize), callback: callback)
			//try readBuffer.mapAsync2(mode: .read, offset: 0, size: Int(outputByteSize), callback: callback)
			gpu.instance.processEvents()
			//device.tick()

			while ( !IsFinished )
			{
				try await Task.sleep(for:.milliseconds(1))
				let state = readBuffer.mapState
				//print("read-buffer mapped state; \(state)")
				if ( state == .mapped )
				{
					IsFinished = true
				}
				else if ( state != .pending )
				{
					throw RuntimeError("Mapping failed")
				}
				gpu.instance.processEvents()
				//device.tick()
			}
		}
		
		
		let outputBufferView = readBuffer.getConstMappedRange(offset: 0)
		guard let outputBufferView else
		{
			throw RuntimeError("No buffer view for output buffer")
		}
		let outputBufferView8 = outputBufferView.bindMemory(to: UInt8.self, capacity: Int(outputByteSize) )
		let outputBufferView8Ptr = UnsafeBufferPointer(start: outputBufferView8, count: Int(outputByteSize) )
		
		do
		{
			try onGotOutput(outputBufferView8Ptr)
			readBuffer.unmap()
		}
		catch let error
		{
			readBuffer.unmap()
			throw error
		}
		
	}
}

