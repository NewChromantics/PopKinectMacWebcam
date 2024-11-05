import SwiftUI
import WebGPU
import MetalKit



#if canImport(UIKit)
import UIKit
#else//macos
import AppKit
typealias UIView = NSView
typealias UIColor = NSColor
typealias UIRect = NSRect
typealias UIViewRepresentable = NSViewRepresentable
#endif


//	callback from low-level (metal)view when its time to render
protocol ContentRenderer
{
	func Render(contentRect:CGRect,layer:CAMetalLayer)
}



class WebGpuRenderer
{
	var webgpu : WebGPU.Instance = createInstance()
	var device : Device?
	var windowTextureFormat = TextureFormat.bgra8Unorm

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
	}
	
	
	
	func Render(metalLayer:CAMetalLayer,getCommands:(Device,CommandEncoder,TextureView)->()) throws
	{
		guard let device else
		{
			throw RuntimeError("Waiting for device")
		}
		
		let FinalChainSurface = SurfaceSourceMetalLayer(
			layer: Unmanaged.passUnretained(metalLayer).toOpaque()
		)
		
		var surfaceDesc = SurfaceDescriptor()
		surfaceDesc.nextInChain = FinalChainSurface
		let surface = webgpu.createSurface(descriptor: surfaceDesc)
		surface.configure(config: .init(device: device, format: windowTextureFormat, width: 800, height: 600))
		
		let surfaceView = try surface.getCurrentTexture().texture.createView()
		
		let encoder = device.createCommandEncoder()
		
		
		//	let caller provide render commands
		getCommands(device,encoder,surfaceView)
		
		
		let commandBuffer = encoder.finish()
		device.queue.submit(commands: [commandBuffer])
		
		surface.present()
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

