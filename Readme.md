Pop Kinect Webcam
==========================
- Expose Kinect depth streams as webcams in macos


Developement
==================
Run Extensions outside system dir and host app outside of `/Applications`
---------------------------
- https://developer.apple.com/documentation/driverkit/debugging_and_testing_system_extensions?language=objc
- Disable system integrity https://developer.apple.com/documentation/security/disabling-and-enabling-system-integrity-protection?language=objc
	- Boot in recovery mode
	- run `csrutil disable`
- Enable unsigned system extensions
	- `systemextensionsctl developer on`

Debugging Extension
-------------------------
- Run xcode as root `sudo /Applications/Xcode.app/etc etc`
- Attach to a `com.newchromantic....` process (may auto detect!)
- Run a camera app which instances a camera device

Troubleshooting
------------------
- Upon activation `extension category returned error`
	- This is something wrong with the AppGroup identifier (!)
	- Make sure an app group is registered. `gr: not sure if it actually uses this`
	- Make sure app identifier uses this app group `gr: not sure if used either!`
	- Set entitlement app group to the app identifier `XXXXXXX.com.co.appident` - not `group.appgroup` as specifed in docs
	- May also require privacy description, even if not supplied
