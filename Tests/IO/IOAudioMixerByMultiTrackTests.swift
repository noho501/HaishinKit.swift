import Foundation
import AVFoundation
import XCTest

@testable import HaishinKit

final class IOAudioMixerByMultiTrackTests: XCTestCase {
    func testpKeep44100() {
        let mixer = IOAudioMixerByMultiTrack()
        mixer.settings = .init(
            channels: 1,
            sampleRate: 44100
        )
        mixer.append(0, buffer: CMAudioSampleBufferFactory.makeSinWave(48000, numSamples: 1024, channels: 1)!)
        XCTAssertEqual(mixer.outputFormat?.sampleRate, 44100)
        mixer.append(0, buffer: CMAudioSampleBufferFactory.makeSinWave(44100, numSamples: 1024, channels: 1)!)
        XCTAssertEqual(mixer.outputFormat?.sampleRate, 44100)
    }

    func testInputFormats() {
        let mixer = IOAudioMixerByMultiTrack()
        mixer.settings = .init(
            channels: 1,
            sampleRate: 44100
        )
        mixer.append(0, buffer: CMAudioSampleBufferFactory.makeSinWave(48000, numSamples: 1024, channels: 1)!)
        mixer.append(1, buffer: CMAudioSampleBufferFactory.makeSinWave(44100, numSamples: 1024, channels: 1)!)
        let inputFormats = mixer.inputFormats
        XCTAssertEqual(inputFormats[0]?.sampleRate, 48000)
        XCTAssertEqual(inputFormats[1]?.sampleRate, 44100)
    }
}
