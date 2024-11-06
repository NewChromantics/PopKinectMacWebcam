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


func GetTestTexture(device:Device) -> WebGPU.Texture
{
	let kTextureWidth = UInt32(5);
	let kTextureHeight = UInt32(7);
	let size = Extent3d(width: kTextureWidth,height: kTextureHeight)

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
										format:TextureFormat.rgba8Unorm
										)
	let texture = device.createTexture(descriptor: description)

	let layout = TextureDataLayout(offset: 0,bytesPerRow: kTextureWidth*4)

	//	copy-this-texture instructoin
	let copyMeta = ImageCopyTexture(texture: texture)
	
	textureDataFlat.withUnsafeBytes
	{
		UnsafeRawBufferPointer in
			device.queue.writeTexture(destination: copyMeta, data: UnsafeRawBufferPointer, dataLayout: layout, writeSize: size )
	}
	
	return texture
}


class CameraPreviewInstance
{
	//	todo: need to save these per-device
	var pipeline : WebGPU.RenderPipeline?
	var vertexBuffer : WebGPU.Buffer?
	var vertexCount : UInt32?
	var texture : Texture?
	var sampler : Sampler?
	var bindGroup : BindGroup?
	
	//	can we get this from the surface view?
	var windowTextureFormat = TextureFormat.bgra8Unorm

	func InitTexture(device:Device)
	{
		self.texture = GetTestTexture(device: device)
		self.sampler = device.createSampler()

	}
	
	
	func InitResources(device:Device)
	{
		//	already initialised
		if ( pipeline != nil )
		{
			return
		}
		
		InitTexture(device: device)
		
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
		
		let bindMeta = BindGroupDescriptor(label: "Texture bind",
			layout: pipeline.getBindGroupLayout(groupIndex:0),
			entries: [
				BindGroupEntry( binding: 0, sampler: self.sampler! ),
				BindGroupEntry( binding: 1, textureView: self.texture!.createView() )
			]
		)
		
		self.bindGroup = device.createBindGroup(descriptor: bindMeta)
		
		
		
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
	
	func Render(device:Device,encoder:CommandEncoder,surfaceView:TextureView)
	{
		InitResources(device: device)
		guard let pipeline else
		{
			return
		}
		
		let renderPass = encoder.beginRenderPass(descriptor: RenderPassDescriptor(
			colorAttachments: [
				RenderPassColorAttachment(
					view: surfaceView,
					loadOp: .clear,
					storeOp: .store,
					clearValue: WebGPU.Color(r: 0, g: 1, b: 1, a: 1))]))
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

