import Foundation
import TGSPlayerKit
import UIKit

final class DemoViewController: UIViewController {
    private let animationLoader = TGSRLottieAnimationLoader()
    private let titleLabel = UILabel()
    private let metricsLabel = UILabel()
    private let messagesTitleLabel = UILabel()
    private let messageTableView = RoomMessageListView()
    private let giftPanelView = GiftPanelView()

    private var catalog: DemoGiftCatalog = .empty
    private var messages: [DemoMessage] = [
        .system("公屏消息列表"),
        .system("从底部礼物面板选择礼物，点击后会发送到这里。TGS 礼物会在消息里播放。")
    ]
    private var frameCallbackCount = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.06, green: 0.07, blue: 0.08, alpha: 1.0)
        catalog = DemoGiftCatalog.loadFromBundle()
        configureHeader()
        configureMessages()
        configureGiftPanel()
        updateMetrics()
    }

    private func configureHeader() {
        titleLabel.text = "TGSPlayerKit Gift Demo"
        titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        titleLabel.textColor = .white

        metricsLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        metricsLabel.textColor = UIColor(white: 1.0, alpha: 0.72)
        metricsLabel.numberOfLines = 2

        let stack = UIStackView(arrangedSubviews: [titleLabel, metricsLabel])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16)
        ])
    }

    private func configureMessages() {
        messagesTitleLabel.text = "消息列表"
        messagesTitleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        messagesTitleLabel.textColor = UIColor(white: 1, alpha: 0.82)
        messagesTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        messageTableView.separatorStyle = .none
        messageTableView.dataSource = self
        messageTableView.estimatedRowHeight = 168
        messageTableView.rowHeight = UITableView.automaticDimension
        messageTableView.register(MessageCell.self, forCellReuseIdentifier: MessageCell.reuseIdentifier)
        messageTableView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(messagesTitleLabel)
        view.addSubview(messageTableView)
        NSLayoutConstraint.activate([
            messagesTitleLabel.topAnchor.constraint(equalTo: metricsLabel.bottomAnchor, constant: 12),
            messagesTitleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            messagesTitleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            messageTableView.topAnchor.constraint(equalTo: messagesTitleLabel.bottomAnchor, constant: 8),
            messageTableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            messageTableView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private func configureGiftPanel() {
        giftPanelView.configure(stickers: catalog.stickers)
        giftPanelView.onSelectSticker = { [weak self] sticker in
            self?.sendSticker(sticker)
        }
        giftPanelView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(giftPanelView)
        NSLayoutConstraint.activate([
            giftPanelView.topAnchor.constraint(equalTo: messageTableView.bottomAnchor),
            giftPanelView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            giftPanelView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            giftPanelView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            giftPanelView.heightAnchor.constraint(equalToConstant: 318)
        ])
    }

    private func sendSticker(_ sticker: DemoSticker) {
        messages.append(.gift(sticker))
        let indexPath = IndexPath(row: messages.count - 1, section: 0)
        messageTableView.insertRows(at: [indexPath], with: .automatic)
        messageTableView.scrollToRow(at: indexPath, at: .bottom, animated: true)
        updateMetrics()
    }

    private func updateMetrics() {
        let giftCount = messages.filter {
            if case .gift = $0 { return true }
            return false
        }.count
        metricsLabel.text = "\(catalog.stickerCount) stickers · \(catalog.tgsStickerCount) playable TGS · \(giftCount) sent · \(frameCallbackCount) rendered frames"
    }
}

extension DemoViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        messages.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: MessageCell.reuseIdentifier,
            for: indexPath
        ) as! MessageCell
        cell.configure(
            message: messages[indexPath.row],
            loader: animationLoader
        ) { [weak self] in
            self?.frameCallbackCount += 1
            self?.updateMetrics()
        }
        return cell
    }
}

private enum DemoMessage {
    case system(String)
    case gift(DemoSticker)
}

private struct DemoGiftCatalog {
    let stickers: [DemoSticker]

    static let empty = DemoGiftCatalog(stickers: [])

    var stickerCount: Int {
        stickers.count
    }

    var tgsStickerCount: Int {
        stickers.count
    }

    static func loadFromBundle() -> DemoGiftCatalog {
        let bundledURLs = Bundle.main.urls(forResourcesWithExtension: "tgs", subdirectory: "tgs")
            ?? Bundle.main.urls(forResourcesWithExtension: "tgs", subdirectory: nil)
            ?? []
        let stickers = bundledURLs
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map(DemoSticker.init(fileURL:))
        return DemoGiftCatalog(stickers: stickers)
    }
}

private struct DemoSticker {
    let fileURL: URL
    let id: Int
    let stickerName: String

    init(fileURL: URL) {
        self.fileURL = fileURL
        let name = fileURL.deletingPathExtension().lastPathComponent
        id = Int(name) ?? 0
        stickerName = name
    }

    var playbackPath: String {
        fileURL.path
    }
}

private final class GiftPanelView: UIView {
    var onSelectSticker: ((DemoSticker) -> Void)?

    private let titleLabel = UILabel()
    private let layout = UICollectionViewFlowLayout()
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)

    private var stickers: [DemoSticker] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 1.0)
        layer.cornerRadius = 18
        layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        layer.masksToBounds = true
        configureSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configure(stickers: [DemoSticker]) {
        self.stickers = stickers
        collectionView.reloadData()
    }

    private func configureSubviews() {
        titleLabel.text = "TGS 文件"
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .white

        layout.minimumLineSpacing = 12
        layout.minimumInteritemSpacing = 10
        layout.sectionInset = UIEdgeInsets(top: 12, left: 16, bottom: 18, right: 16)

        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.alwaysBounceVertical = true
        collectionView.register(GiftCell.self, forCellWithReuseIdentifier: GiftCell.reuseIdentifier)

        let stack = UIStackView(arrangedSubviews: [titleLabel, collectionView])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

}

extension GiftPanelView: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return stickers.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: GiftCell.reuseIdentifier,
            for: indexPath
        ) as! GiftCell
        cell.configure(sticker: stickers[indexPath.item])
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        onSelectSticker?(stickers[indexPath.item])
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let available = collectionView.bounds.width - layout.sectionInset.left - layout.sectionInset.right - (layout.minimumInteritemSpacing * 3)
        let width = floor(available / 4)
        return CGSize(width: max(68, width), height: 92)
    }
}

private final class GiftCell: UICollectionViewCell {
    static let reuseIdentifier = "GiftCell"

    private let previewView = TGSStickerShimmerEffectView()
    private let nameLabel = UILabel()
    private let typeLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = UIColor(white: 1, alpha: 0.08)
        contentView.layer.cornerRadius = 8
        contentView.layer.masksToBounds = true

        previewView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(previewView)

        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.textColor = UIColor(white: 1, alpha: 0.88)
        nameLabel.textAlignment = .center
        nameLabel.adjustsFontSizeToFitWidth = true
        nameLabel.minimumScaleFactor = 0.75
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(nameLabel)

        typeLabel.font = .systemFont(ofSize: 9, weight: .bold)
        typeLabel.textAlignment = .center
        typeLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(typeLabel)

        NSLayoutConstraint.activate([
            previewView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            previewView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            previewView.widthAnchor.constraint(equalToConstant: 52),
            previewView.heightAnchor.constraint(equalToConstant: 52),
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            nameLabel.topAnchor.constraint(equalTo: previewView.bottomAnchor, constant: 6),
            typeLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            typeLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            typeLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            typeLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -4)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        previewView.stopAnimating()
        previewView.setSilhouette(nil)
    }

    func configure(sticker: DemoSticker) {
        nameLabel.text = sticker.stickerName
        typeLabel.text = "TGS"
        typeLabel.textColor = UIColor(red: 0.25, green: 0.70, blue: 1.0, alpha: 1)
        previewView.setSilhouette(nil)
        previewView.startAnimating()
    }
}

private final class MessageCell: UITableViewCell {
    static let reuseIdentifier = "MessageCell"

    private let bubbleView = UIView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let playerView = TGSPlayerView()
    private var source: TGSAnimatedStickerLocalFileSource?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        configureSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        playerView.frameUpdated = { _, _ in }
        playerView.silhouette = nil
        playerView.reset()
        source = nil
    }

    func configure(
        message: DemoMessage,
        loader: TGSLottieAnimationLoading,
        onFrame: @escaping () -> Void
    ) {
        switch message {
        case let .system(text):
            titleLabel.text = text
            subtitleLabel.text = nil
            playerView.isHidden = true
            playerView.reset()
        case let .gift(sticker):
            titleLabel.text = "发送 \(sticker.stickerName).tgs"
            subtitleLabel.text = "本地 TGS 文件 #\(sticker.id)"
            playerView.isHidden = false
            playerView.animationLoader = loader
            playerView.frameUpdated = { _, _ in onFrame() }
            playerView.silhouette = nil
            let source = TGSAnimatedStickerLocalFileSource(path: sticker.playbackPath)
            self.source = source
            playerView.setup(
                source: source,
                width: 128,
                height: 128,
                playbackMode: .loop,
                mode: .cached
            )
            playerView.overrideVisibility = true
            playerView.visibility = true
            playerView.autoplay = true
        }
    }

    private func configureSubviews() {
        bubbleView.backgroundColor = UIColor(white: 1, alpha: 0.09)
        bubbleView.layer.cornerRadius = 8
        bubbleView.layer.masksToBounds = true
        bubbleView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(bubbleView)

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 0

        subtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.textColor = UIColor(white: 1, alpha: 0.62)

        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.layer.cornerRadius = 8
        playerView.layer.masksToBounds = true
        playerView.backgroundColor = UIColor(white: 1, alpha: 0.06)

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 4

        let row = UIStackView(arrangedSubviews: [playerView, textStack])
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        bubbleView.addSubview(row)

        NSLayoutConstraint.activate([
            bubbleView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            bubbleView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            bubbleView.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),
            bubbleView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            row.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: 10),
            row.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -12),
            row.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: -10),
            playerView.widthAnchor.constraint(equalToConstant: 86),
            playerView.heightAnchor.constraint(equalToConstant: 86)
        ])
    }
}

private final class RoomMessageListView: UITableView {
    init() {
        super.init(frame: .zero, style: .plain)
        backgroundColor = UIColor(white: 1, alpha: 0.035)
        layer.cornerRadius = 8
        layer.masksToBounds = true
        contentInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}
