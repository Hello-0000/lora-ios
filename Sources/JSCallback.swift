import Foundation

/// H5 侧注册的回调函数名，原生侧必须用对象字面量调用：
/// window.onUDPCallback({...})
enum JSCallback: String {
    case wifi = "onWiFiMethodCallback"
    case udp = "onUDPCallback"
    case modbus = "onModbusTCPCallback"
    case nfc = "onNFCCallback"
    case qr = "onQRCallback"
    case network = "onCheckNetworkCallback"
    case backButton = "onAndroidBackBtn"
}
