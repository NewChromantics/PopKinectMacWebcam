import PopCameraDevice
import Cocoa



//	dont override this, or the observable object breaks
final class PopCameraDeviceManager : NSObject, ObservableObject
{
	var enumDevicesThread : Task<Void,any Error>!

	@Published var devices : [PopCameraDevice.EnumDeviceMeta] = []
	
	var serialPrefixFilter : String
	
	init(serialPrefixFilter:String="")
	{
		self.serialPrefixFilter = serialPrefixFilter
		super.init()
		self.enumDevicesThread = Task
		{
			try await self.WatchForNewDevicesThread()
		}
	}
	
	deinit
	{
		enumDevicesThread.cancel()
	}
	
	func WatchForNewDevicesThread() async throws
	{
		while ( true )
		{
			do
			{
				let Devices = try PopCameraDevice.EnumDevices(requireSerialPrefix: serialPrefixFilter)
				OnFoundDevices( Devices )
			}
			catch let error
			{
				print("Error enumerating devices; \(error.localizedDescription)")
			}

			//	will throw if task cancelled
			try await Task.sleep(for: .seconds(10))
		}
	}
	
	func OnFoundDevices(_ deviceMetas:[PopCameraDevice.EnumDeviceMeta])
	{
		//	gotta change observables on main thread
		DispatchQueue.main.async
		{
			self.devices = deviceMetas
		}
	}
}
