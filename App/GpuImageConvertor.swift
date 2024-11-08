import SwiftUI
import WebGPU



enum ConvertorImageFormat
{
	case rgb8
	case bgra8
	
	//	will throw for unhandled or unconvertible types
	func GetTextureFormat() throws -> TextureFormat
	{
		switch self
		{
			case .rgb8:		throw RuntimeError("rgb8 has no TextureFormat equivilent")
			case .bgra8:	return TextureFormat.bgra8Unorm
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

struct TextureMeta
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
			return try imageFormat.GetTextureFormat()
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
	var inputMeta : TextureMeta
	//var outputTexture : Texture
	//var outputMeta : TextureMeta
	var outputBuffer : Buffer
	var outputMeta : TextureMeta
	var outputBufferCopyMeta : ImageCopyBuffer
	{
		get throws
		{
			let layout = try TextureDataLayout(offset: 0,bytesPerRow: outputMeta.bytesPerRow)
			return ImageCopyBuffer(layout: layout, buffer: outputBuffer)
		}
	}
	
	init(device:WebGPU.Device,inputMeta:TextureMeta,intputData:UnsafeRawBufferPointer,outputMeta:TextureMeta) throws
	{
		//	todo: this needs to be aligned to 32(in total) - do we need to pad, or will webgpu pad it?
		let inputByteSize = try inputMeta.byteSize
		let inputUsage = BufferUsage(rawValue: BufferUsage.storage.rawValue | BufferUsage.copyDst.rawValue )
		let inputBufferDescription = BufferDescriptor(label: "convertImageInput", usage:inputUsage, size: inputByteSize )
		self.inputBuffer = device.createBuffer(descriptor: inputBufferDescription)
		self.inputMeta = inputMeta

		let outputByteSize = try outputMeta.byteSize
		let outputUsage = BufferUsage(rawValue: BufferUsage.storage.rawValue | BufferUsage.copyDst.rawValue | BufferUsage.copySrc.rawValue )
		let outputBufferDescription = BufferDescriptor(label: "convertImageOutput", usage:outputUsage, size: outputByteSize )
		self.outputBuffer = device.createBuffer(descriptor: outputBufferDescription)
		self.outputMeta = outputMeta

		//	gr: is this the right place to do this?
		device.queue.writeBuffer( inputBuffer, bufferOffset: 0, data: intputData)
	}
	
	var ConvertImageKernelSource : String
	{
		return """
		//	no byte access, so access is 32 bit and we need to work around that
		@group(0) @binding(0) var<storage, read_write> inputRgb8 : array<u32>;
		@group(0) @binding(1) var<storage, read_write> outputBgra8 : array<u32>;

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
			let data32 : u32 = 0xff00ff00;
			//let red = (data32 >> 24) & 0xff;
			let red = 255;
			let green = 255;
			let blue = 0;
			let alpha = 255;

			let bgra32 = (blue<<0) | (green<<8) | (red<<16) | (alpha<<24);
			outputBgra8[pixelIndex] = u32(bgra32);
		}
		"""
	}
	
	//	put new data into the input buffer
	//	func writeData
	
	func AddConvertPass(device:Device,encoder:CommandEncoder)
	{
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
		let kernelStage = ProgrammableStageDescriptor(module: kernelModule)
		
		let pipelineDescription = ComputePipelineDescriptor(
			label: "ConvertImagePipeline",
			layout: pipelineLayout,
			compute: kernelStage
		)
		let pipeline = device.createComputePipeline(descriptor:pipelineDescription)
		
		let bindMeta = BindGroupDescriptor(label: "Buffer Bind",
										   layout: pipeline.getBindGroupLayout(groupIndex:0),
										   entries: [
											BindGroupEntry( binding: 0, buffer: self.inputBuffer ),
											BindGroupEntry( binding: 1, buffer: self.outputBuffer )
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


