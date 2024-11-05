import SwiftUI
import WebGPU
import MetalKit


struct Vertex {
	var position: (Float, Float, Float)
	var color: (Float, Float, Float)
}





#if canImport(UIKit)
import UIKit
#else//macos
import AppKit
typealias UIView = NSView
typealias UIColor = NSColor
typealias UIRect = NSRect
typealias UIViewRepresentable = NSViewRepresentable
#endif


//	wrapper on top of an animation+state (rather than using a function pointer)
protocol ContentRenderer
{
	func Render(contentRect:CGRect,layer:CAMetalLayer)
}




class CameraPreviewManager
{
	var webgpu : WebGPU.Instance = createInstance()
	var device : Device?
	var windowTextureFormat = TextureFormat.bgra8Unorm
	var pipeline : WebGPU.RenderPipeline?
	var vertexBuffer : WebGPU.Buffer?

	var initTask : Task<Void,any Error>!
	var error : String?
	
	init()
	{
		//super.init()
		
		initTask = Task
		{
			try await Init()
		}
	}
	
	func OnError(_ error:String)
	{
		print("CameraPreviewManager error; \(error)")
		self.error = error
	}
	
	func OnDeviceUncapturedError(errorType:ErrorType,errorMessage:String)
	{
		OnError("\(errorType)/\(errorMessage)")
	}
	
	func Init() async throws
	{
		let adapter = try await webgpu.requestAdapter()
		print("Using adapter: \(adapter.info.device)")
		
		self.device = try await adapter.requestDevice()
		device!.setUncapturedErrorCallback(OnDeviceUncapturedError)
		/*
		let surface = GetSurfaceDescriptor
		let surface  = webgpu.createSurface(descriptor: SurfaceDescriptor)
		 */
		InitResources(device: device!)
	}
	
	func InitResources(device:Device)
	{
		let vertexShaderSource = """
		struct VertexOut {
			@builtin(position) position : vec4<f32>,
			@location(0) color: vec4<f32>
		};
	
		@vertex fn main(
			@location(0) position : vec4<f32>,
			@location(1) color : vec4<f32>) -> VertexOut {
			var output : VertexOut;
			output.position = position;
			output.color = color;
			return output;
		}
	"""
		
		let fragmentShaderSource = """
		@fragment fn main(
			@location(0) color : vec4<f32>) -> @location(0) vec4<f32> {
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
		
		self.pipeline = device.createRenderPipeline(descriptor: RenderPipelineDescriptor(
			vertex: VertexState(
				module: vertexShader,
				entryPoint: "main",
				buffers: [
					VertexBufferLayout(
						arrayStride: UInt64(MemoryLayout<Vertex>.stride),
						attributes: [
							VertexAttribute(
								format: .float32x3,
								offset: UInt64(MemoryLayout.offset(of: \Vertex.position)!),
								shaderLocation: 0),
							VertexAttribute(
								format: .float32x3,
								offset: UInt64(MemoryLayout.offset(of: \Vertex.color)!),
								shaderLocation: 1)])]),
			fragment: FragmentState(
				module: fragmentShader,
				entryPoint: "main",
				targets: [
					ColorTargetState(format: windowTextureFormat)])))
		
		let vertexData = [
			Vertex(position: (0, 0.5, 0), color: (1, 0, 0)),
			Vertex(position: (-0.5, -0.5, 0), color: (0, 1, 0)),
			Vertex(position: (0.5, -0.5, 0), color: (0, 0, 1))
		]
		
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
	
	func Render(metalLayer:CAMetalLayer) throws
	{
		guard let device else
		{
			throw RuntimeError("Waiting for device")
		}
		guard let pipeline else
		{
			throw RuntimeError("Waiting for pipeline")
		}
		
		let FinalChainSurface = SurfaceSourceMetalLayer(
			layer: Unmanaged.passUnretained(metalLayer).toOpaque()
		)
		
		var surfaceDesc = SurfaceDescriptor()
		surfaceDesc.nextInChain = FinalChainSurface
		let surface = webgpu.createSurface(descriptor: surfaceDesc)
		surface.configure(config: .init(device: device, format: windowTextureFormat, width: 800, height: 600))
		
		
		let encoder = device.createCommandEncoder()
		
		let renderPass = encoder.beginRenderPass(descriptor: RenderPassDescriptor(
			colorAttachments: [
				RenderPassColorAttachment(
					view: try surface.getCurrentTexture().texture.createView(),
					loadOp: .clear,
					storeOp: .store,
					clearValue: WebGPU.Color(r: 0, g: 0, b: 0, a: 1))]))
		renderPass.setPipeline(pipeline)
		renderPass.setVertexBuffer(slot: 0, buffer: vertexBuffer)
		renderPass.draw(vertexCount: 3)
		renderPass.end()
		
		let commandBuffer = encoder.finish()
		device.queue.submit(commands: [commandBuffer])
		
		surface.present()
	}
}

let cameraPreviewInstance = CameraPreviewManager()




public struct CameraPreview : View, ContentRenderer
{
	public init()
	{
	}
	
	
	public var body : some View
	{
		RenderViewRep(contentRenderer: self)
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.background(.red)
	}

	func Render(contentRect: CGRect,layer:CAMetalLayer)
	{
		do
		{
			try cameraPreviewInstance.Render(metalLayer: layer)
		}
		catch let Error
		{
			print("Render error; \(Error.localizedDescription)")
		}
	}
	
}


/*
//	this is the delegate
//	is this where we want webgpu
class Coordinator : NSObject, MTKViewDelegate
{
	var parent: MetalView
	var metalDevice: MTLDevice!
	var metalCommandQueue: MTLCommandQueue!
	var context : CIContext
	var clearColour : CGColor
	var clearRgba : [CGFloat]
	{
		return clearColour.components ?? [1,0,1,1]
	}
	
	init(_ parent: MetalView,clearColour : CGColor)
	{
		self.clearColour = clearColour
		self.parent = parent
		
		if let metalDevice = MTLCreateSystemDefaultDevice()
		{
			self.metalDevice = metalDevice
		}
		self.metalCommandQueue = metalDevice.makeCommandQueue()!
		context = CIContext(mtlDevice: metalDevice)
		
		super.init()
	}
	
	func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize)
	{
	}
	
	/*
	 func draw(in view: MTKView) {
	 guard let drawable = view.currentDrawable else {
	 return
	 }
	 let commandBuffer = metalCommandQueue.makeCommandBuffer()
	 let rpd = view.currentRenderPassDescriptor
	 rpd?.colorAttachments[0].clearColor = MTLClearColorMake(0, 1, 0, 1)
	 rpd?.colorAttachments[0].loadAction = .clear
	 rpd?.colorAttachments[0].storeAction = .store
	 let re = commandBuffer?.makeRenderCommandEncoder(descriptor: rpd!)
	 re?.endEncoding()
	 commandBuffer?.present(drawable)
	 commandBuffer?.commit()
	 }
	 */
	func draw(in view: MTKView)
	{
		guard let drawable = view.currentDrawable else {
			return
		}
		
		
		let colorSpace = CGColorSpaceCreateDeviceRGB()
		
		let commandBuffer = metalCommandQueue.makeCommandBuffer()
		
		let rpd = view.currentRenderPassDescriptor
		rpd?.colorAttachments[0].clearColor = MTLClearColorMake( clearRgba[0], clearRgba[1], clearRgba[2], clearRgba[3] )
		rpd?.colorAttachments[0].loadAction = .clear
		rpd?.colorAttachments[0].storeAction = .store
		
		let re = commandBuffer?.makeRenderCommandEncoder(descriptor: rpd!)
		re?.endEncoding()
		/*
		 context.render((AppState.shared.rawImage ?? AppState.shared.rawImageOriginal)!,
		 to: drawable.texture,
		 commandBuffer: commandBuffer,
		 bounds: AppState.shared.rawImageOriginal!.extent,
		 colorSpace: colorSpace)
		 */
		commandBuffer?.present(drawable)
		commandBuffer?.commit()
	}
}
*/

//	our own abstracted low level view, so we can get access to the layer
class RenderView : UIView
{
	//var wantsLayer: Bool	{	return true	}
	//	gr: don't seem to need this
	//override var wantsUpdateLayer: Bool { return true	}
	public var contentRenderer : ContentRenderer
	//var vsync : VSyncer? = nil
	
#if os(macOS)
	override var isFlipped: Bool { return true	}
#endif
	
	required init?(coder: NSCoder)
	{
		fatalError("init(coder:) has not been implemented")
	}
	
	//	on macos this is CALayer? on ios, it's just CALayer. So this little wrapper makes them the same
	var viewLayer : CALayer?
	{
		return self.layer
	}
	
	var metalLayer : CAMetalLayer
	{
		return (self.viewLayer as! CAMetalLayer?)!
	}
	
	
	init(contentRenderer:ContentRenderer)
	{
		self.contentRenderer = contentRenderer
		
		super.init(frame: .zero)
		// Make this a layer-hosting view. First set the layer, then set wantsLayer to true.
		
#if os(macOS)
		wantsLayer = true
		//self.needsLayout = true
#endif
		self.layer = CAMetalLayer()
		//viewLayer!.addSublayer(metalLayer)
		
		//vsync = VSyncer(Callback: Render)
	}
	
	
	func startRenderLoop()
	{
	}
	
	
	
#if os(macOS)
	override func layout()
	{
		super.layout()
		OnContentsChanged()
	}
#else
	override func layoutSubviews()
	{
		super.layoutSubviews()
		OnContentsChanged()
	}
#endif
	
	func OnContentsChanged()
	{
		let contentRect = self.bounds
		
		//	render
		contentRenderer.Render(contentRect: contentRect, layer:metalLayer)
	}
	
	@objc func Render()
	{
		//self.layer?.setNeedsDisplay()
		OnContentsChanged()
	}
	
}


struct RenderViewRep : UIViewRepresentable
{
	typealias UIViewType = RenderView
	typealias NSViewType = RenderView
	
	var contentRenderer : ContentRenderer
	
	var renderView : RenderView?
	
	init(contentRenderer:ContentRenderer)
	{
		self.contentRenderer = contentRenderer
		//contentLayer.contentsGravity = .resizeAspect
	}
		
	
	
	func makeUIView(context: Context) -> RenderView
	{
		let view = RenderView(contentRenderer: contentRenderer)
		return view
	}
	
	func makeNSView(context: Context) -> RenderView
	{
		let view = RenderView(contentRenderer: contentRenderer)
		return view
	}
	
	//	gr: this occurs when the RenderViewRep() is re-initialised, (from uiview redraw)
	//		but the UIView underneath has persisted
	func updateUIView(_ view: RenderView, context: Context)
	{
		view.contentRenderer = self.contentRenderer
	}
	func updateNSView(_ view: RenderView, context: Context)
	{
		updateUIView(view,context: context)
	}
}


/*
//	example metal view
//	gr: see https://github.com/NewChromantics/PopEngine/blob/1d2824161f44fa2fe6a4e239ba9082224c4b208f/src/PopEngineGui.swift#L241
//		for my XXXViewRepresentable abstraction for ios & macos and metal vs opengl
struct MetalView : UIViewRepresentable
{
	typealias UIViewType = RenderView
	typealias NSViewType = RenderView
	
	var clearColour : CGColor
	
	
	
	init(clearColour:CGColor)
	{
		self.clearColour = clearColour
	}
	
	func makeCoordinator() -> Coordinator {
		Coordinator(self,clearColour: clearColour)
	}
	func makeNSView(context: NSViewRepresentableContext<MetalView>) -> MTKView {
		let mtkView = MTKView()
		mtkView.delegate = context.coordinator
		mtkView.preferredFramesPerSecond = 60
		mtkView.enableSetNeedsDisplay = true
		if let metalDevice = MTLCreateSystemDefaultDevice() {
			mtkView.device = metalDevice
		}
		mtkView.framebufferOnly = false
		mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
		mtkView.drawableSize = mtkView.frame.size
		mtkView.enableSetNeedsDisplay = true
		return mtkView
	}
	func updateNSView(_ nsView: MTKView, context: NSViewRepresentableContext<MetalView>) {
	}
	
	
	
}
*/

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

