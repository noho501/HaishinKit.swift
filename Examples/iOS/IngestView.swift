import AVFoundation
import HaishinKit
import SwiftUI

enum FPS: String, CaseIterable, Identifiable {
    case fps15 = "15"
    case fps30 = "30"
    case fps60 = "60"

    var frameRate: Float64 {
        switch self {
        case .fps15:
            return 15
        case .fps30:
            return 30
        case .fps60:
            return 60
        }
    }

    var id: Self { self }
}

enum VideoEffectItem: String, CaseIterable, Identifiable, Sendable {
    case none
    case monochrome

    var id: Self { self }

    func makeVideoEffect() -> VideoEffect? {
        switch self {
        case .none:
            return nil
        case .monochrome:
            return MonochromeEffect()
        }
    }
}

struct IngestView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var model = IngestViewModel()

    var body: some View {
        ZStack {
            VStack {
                MTHKSwiftUiView(previewSource: model)
            }
            VStack(alignment: .trailing) {
                HStack(spacing: 16) {
                    Spacer()
                    Button(action: { Task {
                        await model.flipCamera()
                    }}, label: {
                        Image(systemName:
                                "arrow.trianglehead.2.clockwise.rotate.90.camera")
                            .resizable()
                            .scaledToFit()
                            .foregroundColor(.white)
                            .frame(width: 30, height: 30)
                    })
                    Button(action: { Task {
                        await model.toggleTorch()
                    }}, label: {
                        Image(systemName: model.isTorchEnabled ?
                                "flashlight.on.circle.fill" :
                                "flashlight.off.circle.fill")
                            .resizable()
                            .scaledToFit()
                            .foregroundColor(.white)
                            .frame(width: 30, height: 30)
                    })
                }.padding(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 16.0))
                Picker("FPS", selection: $model.currentFPS) {
                    ForEach(FPS.allCases) {
                        Text($0.rawValue).tag($0)
                    }
                }
                .onChange(of: model.currentFPS) { tag in
                    model.setFrameRate(tag.frameRate)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                .padding()
                Spacer()
            }
            VStack {
                Spacer()
                TabView(selection: $model.visualEffectItem) {
                    ForEach(VideoEffectItem.allCases) {
                        Text($0.rawValue).padding()
                    }
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .automatic))
                .frame(height: 120)
                .padding(.bottom, 32)
                .onChange(of: model.visualEffectItem) { tag in
                    model.setVisualEffet(tag)
                }
            }
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    switch model.readyState {
                    case .connecting:
                        Spacer()
                    case .open:
                        Button(action: {
                            model.stopIngest()
                        }, label: {
                            Image(systemName: "stop.circle")
                                .foregroundColor(.white)
                                .font(.system(size: 24))
                        })
                        .frame(width: 60, height: 60)
                        .background(Color.blue)
                        .cornerRadius(30.0)
                        .padding(EdgeInsets(top: 0, leading: 0, bottom: 16.0, trailing: 16.0))
                    case .closing:
                        Spacer()
                    case .closed:
                        Button(action: {
                            model.startIngest()
                        }, label: {
                            Image(systemName: "record.circle")
                                .foregroundColor(.white)
                                .font(.system(size: 24))
                        })
                        .frame(width: 60, height: 60)
                        .background(Color.blue)
                        .cornerRadius(30.0)
                        .padding(EdgeInsets(top: 0, leading: 0, bottom: 16.0, trailing: 16.0))
                    }
                }
            }
        }
        .task {
            let session = AVAudioSession.sharedInstance()
            do {
                // If you set the "mode" parameter, stereo capture is not possible, so it is left unspecified.
                try session.setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetooth])
                try session.setActive(true)
            } catch {
                logger.error(error)
            }
            await model.startRunning()
        }
        .onDisappear {
            Task { await model.stopRunning() }
        }
        .onChange(of: horizontalSizeClass) { _ in
            model.orientationDidChange()
        }.alert(isPresented: $model.isShowError) {
            Alert(
                title: Text("Error"),
                message: Text(model.error?.localizedDescription ?? ""),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}

#Preview {
    IngestView()
}
