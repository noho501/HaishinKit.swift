import Foundation

struct Preference: Sendable {
    // Temp
    static nonisolated(unsafe) var `default` = Preference()

    // var uri = "http://192.168.1.14:1985/rtc/v1/whip/?app=live&stream=livestream"
    var uri = "rtmps://live-api-s.facebook.com:443/rtmp/FB-24873611415599253-0-Ab2Op-Cu8TfKVhy6K8sEsjd0"
    var streamName = "live"

    func makeURL() -> URL? {
        if uri.contains("rtmp://") {
            return URL(string: uri + "/" + streamName)
        }
        return URL(string: uri)
    }
}
