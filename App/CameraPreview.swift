import SwiftUI
import WebGPU
import MetalKit


let webGpuRenderer = WebGPU.WebGpuRenderer()



struct Vertex {
	var position: (Float, Float, Float)
	var color: (Float, Float, Float)
	
	
	static var layout : VertexBufferLayout
	{
		return VertexBufferLayout(
			arrayStride: UInt64(MemoryLayout<Vertex>.stride),
			attributes: Vertex.attributes
			)
	}
	
	static var attributes : [VertexAttribute]
	{
		return [
			VertexAttribute (
				format: .float32x3,
				offset: UInt64(MemoryLayout.offset(of: \Vertex.position)!),
				shaderLocation: 0
			),
			VertexAttribute (
				format: .float32x3,
				offset: UInt64(MemoryLayout.offset(of: \Vertex.color)!),
				shaderLocation: 1
			)
			]
	}
}




class CameraPreviewInstance
{
	//	todo: need to save these per-device
	var pipeline : WebGPU.RenderPipeline?
	var vertexBuffer : WebGPU.Buffer?
	var vertexCount : UInt32?
	
	//	can we get this from the surface view?
	var windowTextureFormat = TextureFormat.bgra8Unorm

	
	func InitResources(device:Device)
	{
		//	already initialised
		if ( pipeline != nil )
		{
			return
		}
		
		let vertexShaderSource = """
		struct VertexOut {
			@builtin(position) position : vec4<f32>,
			@location(0) color: vec4<f32>
		};

		@vertex fn main(
			@location(0) position : vec4<f32>,
			@location(1) color : vec4<f32>
			) -> VertexOut 
		{
			var output : VertexOut;
			output.position = position;
			output.color = color;
			return output;
		}
		"""
		
		let fragmentShaderSource = """
		@fragment fn main(
			@location(0) color : vec4<f32>
		) -> @location(0) vec4<f32> 
		{
			return color;
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
			buffers: [Vertex.layout]
		)
		
		let pipelineDescription = RenderPipelineDescriptor(
			vertex: vertexDescription,
			fragment: FragmentState(
				module: fragmentShader,
				entryPoint: "main",
				targets: [
					ColorTargetState(format: windowTextureFormat)
				]))
		self.pipeline = device.createRenderPipeline(descriptor:pipelineDescription)
		
		let vertexData = [
			Vertex(position: (0, 0.5, 0), color: (1, 0, 0)),
			Vertex(position: (-0.5, -0.5, 0), color: (0, 1, 0)),
			Vertex(position: (0.5, -0.5, 0), color: (0, 0, 1))
		]
		
		self.vertexCount = UInt32(vertexData.count)
		self.vertexBuffer = vertexData.withUnsafeBytes { vertexBytes -> Buffer in
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

