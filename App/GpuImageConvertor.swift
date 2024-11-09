import SwiftUI
import WebGPU
import CoreMedia


enum ConvertorImageFormat
{
	case rgb8
	case bgra8
	
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
			case .rgb8:		return 3
			case .bgra8:	return 4
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
	
	var channels : UInt32
	{
		get throws
		{
			return try imageFormat.channelCount
		}
	}
	var byteSize : UInt64
	{
		get throws
		{
			return try (UInt64(channels * width * height))
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
	var outputBufferCopyMeta : ImageCopyBuffer
	{
		get throws
		{
			let layout = try TextureDataLayout(offset: 0,bytesPerRow: outputMeta.bytesPerRow)
			return ImageCopyBuffer(layout: layout, buffer: outputBuffer)
		}
	}
	
	init(device:WebGPU.Device,inputMeta:ImageMeta,outputMeta:ImageMeta) throws
	{
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
	}
	
	var ConvertImageKernelSource : String
	{
		return """
		//	no byte access, so access is 32 bit and we need to work around that
		@group(0) @binding(0) var<storage, read> inputRgb8 : array<u32>;
		@group(0) @binding(1) var<storage, read_write> outputBgra8 : array<u32>;

		fn GetInputByte(index:u32) -> u32
		{
			let chunkIndex = index / 4;
			let chunk = inputRgb8[chunkIndex];
			let chunkByteIndex = index % 4;
			let byte = chunk >> (chunkByteIndex*8);
			return byte & 0xff;
		}

		fn GetInputBytes(pixelIndex:u32) -> vec3<u32>
		{
			let rgbChannelCount : u32 = 3;
			let InputIndex = pixelIndex * rgbChannelCount;
			let r = GetInputByte(InputIndex+0);
			let g = GetInputByte(InputIndex+1);
			let b = GetInputByte(InputIndex+2);
			return vec3<u32>( r, g, b );
		}

		@compute @workgroup_size(1,1,1) fn Rgb8ToBgra8(
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
			let rgb = GetInputBytes(pixelIndex);
			let red : u32 = rgb.x;
			let green : u32 = rgb.y;
			let blue : u32 = rgb.z;
			let alpha : u32 = 255;

			let bgra32 = (blue<<0) | (green<<8) | (red<<16) | (alpha<<24);
			outputBgra8[pixelIndex] = u32(bgra32);
		}
		"""
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
			]
		))
		
		let pipelineLayout = device.createPipelineLayout(descriptor: PipelineLayoutDescriptor(
			bindGroupLayouts: [bindGroupLayout])
		)
		
		let kernelSource = ShaderSourceWgsl(code:ConvertImageKernelSource)
		let kernelMeta = ShaderModuleDescriptor(label:"Convert Kernel",nextInChain: kernelSource)
		let kernelModule = device.createShaderModule(descriptor: kernelMeta)
		let kernelStage = ProgrammableStageDescriptor(module: kernelModule, entryPoint: "Rgb8ToBgra8")
		
		let pipelineDescription = ComputePipelineDescriptor(
			label: "ConvertImagePipeline",
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
											BindGroupEntry( binding: 1, buffer: outputBgra8 )
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
	
	
	
	static func Convert(meta:ImageMeta,data:Data,outputFormat:ConvertorImageFormat) async throws -> [UInt8]
	{
		let outputMeta = ImageMeta(width: meta.width, height: meta.height, imageFormat: outputFormat)
		//	todo: make an async gpu.WaitForDevice()
		let device = try await gpu.waitForDevice()
		let convertor = try WebGpuConvertImageFormat( device:device, inputMeta: meta, outputMeta: outputMeta )
		
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
		
		let outputData = [UInt8](outputBufferView8Ptr)
		readBuffer.unmap()

		return outputData
	}
}

