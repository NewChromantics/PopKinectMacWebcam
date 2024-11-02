//
//  main.swift
//  cameraextension
//
//  Created by laurent denoue on 7/1/22.
//

import Foundation
import CoreMediaIO

let providerSource = KinectCameraProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider!)

CFRunLoopRun()
