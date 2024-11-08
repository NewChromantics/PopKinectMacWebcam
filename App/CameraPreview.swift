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

func GetTestRgbImage() -> (TextureMeta,[UInt8])
{
	let CharacterToColourMap : [String:[UInt8]] = [
		"r" : [255,0,0],
		"g" : [0,255,0],
		"b" : [0,0,255],
		"y" : [255,255,0],
		"p" : [255,0,255]
	]
	let inputMeta = TextureMeta(width: 64, height: 1, imageFormat: .rgb8 )
	let PadColour = "b"
	let MissingColour : [UInt8] = [0,0,0]
	let inputString = "rrrrrbbbbbyyyyyrrrrrbbbbbyyyyybbrrrrrbbbbbyyyyyrrrrrbbbbbyyyyybb".padding(toLength: Int(inputMeta.width), withPad: "p", startingAt: 0)
	//let inputString = "r".padding(toLength: Int(inputMeta.width), withPad: PadColour, startingAt: 0)
	let inputData = inputString.map {
		char in
		let rgb = CharacterToColourMap["\(char)"] ?? MissingColour
		return rgb
	}
	let inputDataFlat = inputData.flatMap{$0}

	return (inputMeta,inputDataFlat)
}

class CameraPreviewInstance
{
	//	todo: need to save these per-device
	var pipeline : WebGPU.RenderPipeline?
	var vertexBuffer : WebGPU.Buffer?
	var vertexCount : UInt32?

	var convertor : WebGpuConvertImageFormat?
	var convertedRgba : Texture?

	//	can we get this from the surface view?
	var windowTextureFormat = TextureFormat.bgra8Unorm

	func InitConvertor(device:Device) throws
	{
		//	gr: out seems to need to be a byte-multiple 256
		//	https://developer.mozilla.org/en-US/docs/Web/API/GPUCommandEncoder/copyBufferToTexture
		let outputMeta = TextureMeta(width: 64, height: 10, imageFormat: .bgra8)

		let (inputMeta,inputData) = GetTestRgbImage()
		convertor = try WebGpuConvertImageFormat(device: device, inputMeta: inputMeta, outputMeta: outputMeta)

	}
	
	func InitResources(device:Device) throws
	{
		//	already initialised
		if ( pipeline != nil )
		{
			return
		}
		
		try InitConvertor(device: device)
		
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
			var viewMin = vec2(-1.0,1.0);	//	gr: two integers, causes rendering to fail...
			var viewMax = vec2(1.0,-1.0);
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
	
	func Render(device:Device,encoder:CommandEncoder,surface:Texture,drawFrame:Frame?) throws
	{
		try InitResources(device: device)
		guard let pipeline else
		{
			return
		}
		
		var (inputRgbMeta,inputRgbData) = GetTestRgbImage()
		
		if let pixelBuffer = drawFrame?.pixels
		{
			//	extract bytes
			let w = CVPixelBufferGetWidth(pixelBuffer)
			let h = CVPixelBufferGetHeight(pixelBuffer)
			let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
			let meta = TextureMeta( width: UInt32(w), height: UInt32(h), imageFormat:.rgb8)
			
			inputRgbMeta = meta
			inputRgbData = [UInt8](drawFrame!.originalPixels!)
			
			let outputMeta = TextureMeta( width: UInt32(w), height: UInt32(h), imageFormat:.bgra8)
			convertor = try WebGpuConvertImageFormat(device: device, inputMeta: inputRgbMeta, outputMeta: outputMeta)
		}
			
		convertor?.AddConvertPass(inputData: inputRgbData, device: device, encoder: encoder)
		if ( convertedRgba == nil )
		{
			let rgbaDesc = try TextureDescriptor(	label: "convertedrgba",
												usage: TextureUsage(rawValue: TextureUsage.textureBinding.rawValue|TextureUsage.copyDst.rawValue),
												size: convertor!.outputMeta.extent,
												format: convertor!.outputMeta.textureFormat
			)
			convertedRgba = device.createTexture(descriptor: rgbaDesc)
		}
		//	now should be able to just turn the converted image into a texture!
		try encoder.copyBufferToTexture(source: convertor!.outputBufferCopyMeta, destination: ImageCopyTexture(texture:convertedRgba!), copySize: convertor!.outputMeta.extent)
		
		
		let sampler = device.createSampler()
			
		
		let bindMeta = BindGroupDescriptor(label: "Texture bind",
										   layout: pipeline.getBindGroupLayout(groupIndex:0),
										   entries: [
											BindGroupEntry( binding: 0, sampler: sampler ),
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
	@EnvironmentObject var sinkStreamPusher : SinkStreamPusher
	
	var body : some View
	{
		WebGpuView(contentRenderer: self)
			.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
	

	func Render(contentRect: CGRect,layer:CAMetalLayer)
	{
		do
		{
			try webGpuRenderer.Render(metalLayer: layer)
			{
				device,encoder,surface in
				let lastFrame = sinkStreamPusher.lastFrame
				try cameraPreviewInstance.Render( device: device, encoder: encoder, surface: surface, drawFrame:lastFrame)
			}
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

