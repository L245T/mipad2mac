import AppKit

/// Displays the supplied payment images unchanged; never initiates a payment.
final class SponsorSection: NSObject {
    let view: NSStackView
    private let urls: [URL?]
    override init() {
        urls = [Bundle.main.url(forResource: "wechat", withExtension: "png", subdirectory: "Sponsor"),
                Bundle.main.url(forResource: "alipay", withExtension: "jpg", subdirectory: "Sponsor")]
        view = NSStackView(); view.orientation = .horizontal
        view.spacing = 24; view.alignment = .top
        super.init()
        for (index, name) in ["微信", "支付宝"].enumerated() {
            let title = NativeLayout.text(name, heading: true)
            let image = NSImageView()
            image.image = urls[index].flatMap { NSImage(contentsOf: $0) }
            image.imageScaling = .scaleProportionallyUpOrDown
            image.setAccessibilityLabel("\(name)赞助收款二维码")
            image.widthAnchor.constraint(equalToConstant: 220).isActive = true
            image.heightAnchor.constraint(equalToConstant: 330).isActive = true
            let button = NSButton(title: "查看\(name)原图", target: self, action: #selector(openImage(_:)))
            button.tag = index; button.isEnabled = image.image != nil
            let column = NSStackView(views: [title, image, button])
            column.orientation = .vertical; column.spacing = 10; column.alignment = .centerX
            view.addArrangedSubview(column)
        }
    }
    @objc private func openImage(_ sender: NSButton) {
        guard urls.indices.contains(sender.tag), let url = urls[sender.tag] else { return }
        NSWorkspace.shared.open(url)
    }
}
