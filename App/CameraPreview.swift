import SwiftUI
import WebGPU
import MetalKit


let webGpuRenderer = WebGPU.WebGpuRenderer()



struct Vertex2
{
	//	gr: 2D pos turns into uv & 3d view pos
	var position: (Float, Float)
	
	
	static var layout : VertexBufferLayout
	{
		return VertexBufferLayout(
			arrayStride: UInt64(MemoryLayout<Vertex2>.stride),
			attributes: self.attributes
			)
	}
	
	static var attributes : [VertexAttribute]
	{
		return [
			VertexAttribute (
				format: .float32x2,
				offset: UInt64(MemoryLayout.offset(of: \Vertex2.position)!),
				shaderLocation: 0
			)
			]
	}
}

let QuadVertexes =
[
	Vertex2(position: (0, 0) ),
	Vertex2(position: (1, 0) ),
	Vertex2(position: (1, 1) ),

	Vertex2(position: (1, 1) ),
	Vertex2(position: (0, 1) ),
	Vertex2(position: (0, 0) ),

]

//	is there a proper webgpu api for this?
func GetChannelsFrom(format: TextureFormat) throws -> UInt32
{
	switch format
	{
		case TextureFormat.rgba8Unorm:	return 4
		case TextureFormat.bgra8Unorm:	return 4
		default: throw RuntimeError("TextureFormat to channel count not implemented for (\(format))")
	}
}

func GetTestTexture(device:Device) throws -> WebGPU.Texture
{
	let kTextureWidth = UInt32(5);
	let kTextureHeight = UInt32(7);
	let size = Extent3d(width: kTextureWidth,height: kTextureHeight)
	let format = TextureFormat.rgba8Unorm
	let channels = try GetChannelsFrom(format: format)

	let o : [UInt8] = [255,   0,   0, 255];  // red
	let y : [UInt8] = [255, 255,   0, 255];  // yellow
	let b : [UInt8] = [  0,   0, 255, 255];  // blue
	let textureData : [[UInt8]] = [
		b, o, o, o, o,
		o, y, y, y, o,
		o, y, o, o, o,
		o, y, y, o, o,
		o, y, o, o, o,
		o, y, o, o, o,
		o, o, o, o, o,
	]
	let textureDataFlat = textureData.flatMap{$0}
	
	let description = TextureDescriptor(label: "TestTexture",
										usage: TextureUsage(rawValue: TextureUsage.textureBinding.rawValue|TextureUsage.copyDst.rawValue),
										size: size,
										format: format
										)
	let texture = device.createTexture(descriptor: description)

	let layout = TextureDataLayout(offset: 0,bytesPerRow: kTextureWidth*channels)

	//	copy-this-texture instructoin
	let copyMeta = ImageCopyTexture(texture: texture)
	
	textureDataFlat.withUnsafeBytes
	{
		UnsafeRawBufferPointer in
			device.queue.writeTexture(destination: copyMeta, data: UnsafeRawBufferPointer, dataLayout: layout, writeSize: size )
	}
	
	return texture
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

	var format : TextureFormat
	var channels : UInt32
	{
		get throws
		{
			return try GetChannelsFrom(format: format)
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



class CameraPreviewInstance
{
	//	todo: need to save these per-device
	var pipeline : WebGPU.RenderPipeline?
	var vertexBuffer : WebGPU.Buffer?
	var vertexCount : UInt32?
	var texture : Texture?
	var sampler : Sampler?

	var convertor : WebGpuConvertImageFormat?
	var convertedRgba : Texture?

	//	can we get this from the surface view?
	var windowTextureFormat = TextureFormat.bgra8Unorm

	func InitConvertor(device:Device) throws
	{
		//	gr: out seems to need to be a byte-multiple 256
		//	https://developer.mozilla.org/en-US/docs/Web/API/GPUCommandEncoder/copyBufferToTexture
		let outputMeta = TextureMeta(width: 64, height: 10, format: TextureFormat.bgra8Unorm)

		//	gr: convertor not actually using rgba, is rgb
		let inputMeta = TextureMeta(width: 64, height: 1, format: TextureFormat.rgba8Unorm)
		let o : [UInt8] = [255,   0,   0, 255];  // red
		let y : [UInt8] = [255, 255,   0, 255];  // yellow
		let b : [UInt8] = [  0,   0, 255, 255];  // blue
		let inputData : [[UInt8]] = [
			b, o, o, o, o,
			o, y, y, y, o,
			o, y, o, o, o,
			o, y, y, o, o,
			o, y, o, o, o,
			o, y, o, o, o,
			o, o, o, o, o,
		]
		let inputDataFlat = inputData.flatMap{$0}
		
		
		try inputDataFlat.withUnsafeBytes
		{
			inputBytes in
			convertor = try WebGpuConvertImageFormat(device: device, inputMeta: inputMeta, intputData: inputBytes, outputMeta: outputMeta)
		}
		
	}
	
	func InitTexture(device:Device) throws
	{
		self.texture = try GetTestTexture(device: device)
		self.sampler = device.createSampler()

		/*
		let format = TextureFormat.rgba8Unorm
		//	gr: how do we get this from the format?
		let channels = try GetChannelsFrom(format: format)
		let textureByteSize = channels * self.texture!.width * self.texture!.height
		let readPixelsBufferDescription = BufferDescriptor(label: "ReadBackPixels", usage:.copyDst, size: UInt64(textureByteSize) )
		self.readPixelsBuffer = device.createBuffer(descriptor: readPixelsBufferDescription)
		 */
	}
	
	
	func InitResources(device:Device) throws
	{
		//	already initialised
		if ( pipeline != nil )
		{
			return
		}
		
		try InitConvertor(device: device)
		try InitTexture(device: device)
		
		let vertexShaderSource = """
		struct VertexOut {
			@builtin(position) position : vec4<f32>,
			@location(0) uv : vec2<f32>
		};

		@vertex fn main(
			@location(0) position : vec2<f32>
			) -> VertexOut 
		{
			var output : VertexOut;
			var viewMin = vec2(-1.0,-1.0);	//	gr: two integers, causes rendering to fail...
			var viewMax = vec2(1.0,1.0);
			var viewPos = mix( viewMin, viewMax, position );
			output.position = vec4( viewPos, 0, 1 );
			output.uv = position;
			return output;
		}
		"""
		
		let fragmentShaderSource = """
		@group(0) @binding(0) var ourSampler: sampler;
		@group(0) @binding(1) var ourTexture: texture_2d<f32>;
		@fragment fn main(
			@location(0) uv : vec2<f32>
		) -> @location(0) vec4<f32> 
		{
			return textureSample(ourTexture, ourSampler, uv );
			return vec4( uv, 0, 1 );
		}
		"""
		
		let vertexShader = device.createShaderModule(
			descriptor: ShaderModuleDescriptor(
				label: nil,
				nextInChain: ShaderSourceWgsl(code: vertexShaderSource)))
		
		let fragmentShader = device.createShaderModule(
			descriptor: ShaderModuleDescriptor(
				label: nil,
				nextInChain: ShaderSourceWgsl(code: fragmentShaderSource)))
		
		
		let vertexDescription = VertexState(
			module: vertexShader,
			entryPoint: "main",
			buffers: [Vertex2.layout]
		)
		
		let bindGroupLayout = device.createBindGroupLayout(descriptor: BindGroupLayoutDescriptor(
			entries: [
				BindGroupLayoutEntry(binding: 0,visibility: .fragment,sampler: SamplerBindingLayout(type:.nonFiltering)),
				BindGroupLayoutEntry(binding: 1,visibility: .fragment,texture: TextureBindingLayout(sampleType: .float))
				//BindGroupLayoutEntry(binding: 1,visibility: .fragment,buffer: BufferBindingLayout(type: .uniform))
			]
		))
		
		let pipelineLayout = device.createPipelineLayout(descriptor: PipelineLayoutDescriptor(
			bindGroupLayouts: [bindGroupLayout]))
		
		let pipelineDescription = RenderPipelineDescriptor(
			layout:pipelineLayout,
			vertex: vertexDescription,
			fragment: FragmentState(
				module: fragmentShader,
				entryPoint: "main",
				targets: [
					ColorTargetState(format: windowTextureFormat)
				]))
		self.pipeline = device.createRenderPipeline(descriptor:pipelineDescription)
		guard let pipeline else
		{
			//throw RuntimeError("Failed to make pipeline")
			return
		}
		
		
		
		
		self.vertexCount = UInt32(QuadVertexes.count)
		self.vertexBuffer = QuadVertexes.withUnsafeBytes { vertexBytes -> Buffer in
			let vertexBuffer = device.createBuffer(descriptor: BufferDescriptor(
				usage: .vertex,
				size: UInt64(vertexBytes.count),
				mappedAtCreation: true))
			let ptr = vertexBuffer.getMappedRange(offset: 0, size: 0)
			ptr?.copyMemory(from: vertexBytes.baseAddress!, byteCount: vertexBytes.count)
			vertexBuffer.unmap()
			return vertexBuffer
		}
	}
	
	func Render(device:Device,encoder:CommandEncoder,surface:Texture) throws
	{
		try InitResources(device: device)
		guard let pipeline else
		{
			return
		}
		
		convertor?.AddConvertPass(device: device, encoder: encoder)
		if ( convertedRgba == nil )
		{
			let rgbaDesc = TextureDescriptor(	label: "convertedrgba",
												usage: TextureUsage(rawValue: TextureUsage.textureBinding.rawValue|TextureUsage.copyDst.rawValue),
												size: convertor!.outputMeta.extent,
												format: convertor!.outputMeta.format
			)
			convertedRgba = device.createTexture(descriptor: rgbaDesc)
		}
		//	now should be able to just turn the converted image into a texture!
		try encoder.copyBufferToTexture(source: convertor!.outputBufferCopyMeta, destination: ImageCopyTexture(texture:convertedRgba!), copySize: convertor!.outputMeta.extent)
		
		let bindMeta = BindGroupDescriptor(label: "Texture bind",
										   layout: pipeline.getBindGroupLayout(groupIndex:0),
										   entries: [
											BindGroupEntry( binding: 0, sampler: self.sampler! ),
											BindGroupEntry( binding: 1, textureView: self.convertedRgba!.createView() )
											//BindGroupEntry( binding: 1, textureView: self.texture!.createView() )
										   ]
		)
		
		let bindGroup = device.createBindGroup(descriptor: bindMeta)

		let ClearColour = WebGPU.Color(r: 0, g: 1, b: 1, a: 1)
		let renderPass = encoder.beginRenderPass(descriptor: RenderPassDescriptor(
			colorAttachments: [
				RenderPassColorAttachment(
					view: surface.createView(),
					loadOp: .clear,
					storeOp: .store,
					clearValue: ClearColour
				)]))
		renderPass.setPipeline(pipeline)
		renderPass.setBindGroup(groupIndex: 0,group:bindGroup)
		renderPass.setVertexBuffer(slot: 0, buffer: vertexBuffer!)
		renderPass.draw(vertexCount: self.vertexCount!)
		
		renderPass.end()
	}
}

let cameraPreviewInstance = CameraPreviewInstance()


struct CameraPreview : View, WebGPU.ContentRenderer
{
	var body : some View
	{
		WebGpuView(contentRenderer: self)
			.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
	

	func Render(contentRect: CGRect,layer:CAMetalLayer)
	{
		do
		{
			try webGpuRenderer.Render(metalLayer: layer, getCommands:cameraPreviewInstance.Render )
		}
		catch let Error
		{
			print("Render error; \(Error.localizedDescription)")
		}
	}
	
}

struct CameraPreview_Previews: PreviewProvider
{
	static var previews: some View
	{
		VStack
		{
			CameraPreview()
		}
	}
}

