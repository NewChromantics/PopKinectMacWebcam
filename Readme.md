Virtual camera device for macos that allows you to apply filters over the camera


Troubleshooting
------------------
- Upon activation `extension category returned error`
	- This is something wrong with the AppGroup identifier (!)
	- Make sure an app group is registered. `gr: not sure if it actually uses this`
	- Make sure app identifier uses this app group `gr: not sure if used either!`
	- Set entitlement app group to the app identifier `XXXXXXX.com.co.appident` - not `group.appgroup` as specifed in docs
	- May also require privacy description, even if not supplied
