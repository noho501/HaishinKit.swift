# SRTHaishinKit
- This module supports the SRT protocol. It is separated into its own module due to the large size of the wrapper library for libsrt.

## libsrt.xcframework
- This is a build of https://github.com/Haivision/srt as an xcframework.
- The license under the MPLv2.0.

## 📓 Usage
### Ingest
```swift
let mixer = MediaMixer()
let connection = SRTConnection()
let stream = SRTStream(connection: connection)
let hkView = MTHKView(frame: view.bounds)

Task {
  do {
    try await mixer.attachAudio(AVCaptureDevice.default(for: .audio))
  } catch {
    print(error)
  }

  do {
    try await mixer.attachVideo(AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back))
  } catch {
    print(error)
  }

  await mixer.addOutput(stream)
}

Task { MainActor in
  await stream.addOutput(hkView)
  // add ViewController#view
  view.addSubview(hkView)
}

Task {
  stream.attachAudioPlayer(audioPlayer)
  do {
    try await connection.connect("rtmp://localhost/appName/instanceName")
    try await stream.publish(streamName)
  } catch {
    print(error)
  }
}
```

### Playback
```swift
let connection = SRTConnection()
let stream = SRTStream(connection: connection)
let hkView = MTHKView(frame: view.bounds)
let audioPlayer = AudioPlayer(AVAudioEngine())

Task { MainActor in
  await stream.addOutput(hkView)
  // add ViewController#view
  view.addSubview(hkView)
}

Task {
  // requires attachAudioPlayer
  await stream.attachAudioPlayer(audioPlayer)

  do {
    try await connection.connect("srt://host:port?option=foo")
    try await stream.play()
  } catch {
    print(error)
  }
}
```
