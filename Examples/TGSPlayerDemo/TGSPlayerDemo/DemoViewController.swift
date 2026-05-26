import Foundation
import TGSPlayerKit
import UIKit

final class DemoViewController: UIViewController {
    private let animationLoader = TGSRLottieAnimationLoader()
    private let titleLabel = UILabel()
    private let metricsLabel = UILabel()
    private let messageTableView = RoomMessageListView()
    private let inputBarView = ChatInputBarView()
    private let giftPanelView = GiftPanelView()
    private let giftPanelHeight: CGFloat = 318

    private var catalog: DemoGiftCatalog = .empty
    private var messages: [DemoMessage] = [
        .system("TGSPlayerKit Demo")
    ]
    private var inputBarBottomConstraint: NSLayoutConstraint?
    private var giftPanelVisible = false
    private var frameCallbackCount = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.06, green: 0.07, blue: 0.08, alpha: 1.0)
        catalog = DemoGiftCatalog.loadFromBundle()
        configureHeader()
        configureMessages()
        configureGiftPanel()
        configureInputBar()
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
        messageTableView.separatorStyle = .none
        messageTableView.dataSource = self
        messageTableView.estimatedRowHeight = 168
        messageTableView.rowHeight = UITableView.automaticDimension
        messageTableView.register(MessageCell.self, forCellReuseIdentifier: MessageCell.reuseIdentifier)
        messageTableView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(messageTableView)
        NSLayoutConstraint.activate([
            messageTableView.topAnchor.constraint(equalTo: metricsLabel.bottomAnchor, constant: 12),
            messageTableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            messageTableView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private func configureGiftPanel() {
        giftPanelView.configure(stickers: catalog.stickers, loader: animationLoader)
        giftPanelView.onSelectSticker = { [weak self] sticker, sourceFrame in
            self?.sendSticker(sticker, from: sourceFrame)
        }
        giftPanelView.isHidden = true
        giftPanelView.alpha = 0
        giftPanelView.transform = CGAffineTransform(translationX: 0, y: giftPanelHeight + 24)
        giftPanelView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(giftPanelView)
        NSLayoutConstraint.activate([
            giftPanelView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            giftPanelView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            giftPanelView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            giftPanelView.heightAnchor.constraint(equalToConstant: giftPanelHeight)
        ])
    }

    private func configureInputBar() {
        inputBarView.onTapStickerButton = { [weak self] in
            self?.toggleGiftPanel()
        }
        inputBarView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(inputBarView)

        let bottomConstraint = inputBarView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        inputBarBottomConstraint = bottomConstraint
        NSLayoutConstraint.activate([
            messageTableView.bottomAnchor.constraint(equalTo: inputBarView.topAnchor),
            inputBarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inputBarView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomConstraint,
            inputBarView.heightAnchor.constraint(equalToConstant: 58)
        ])
    }

    private func toggleGiftPanel() {
        setGiftPanelVisible(!giftPanelVisible, animated: true)
    }

    private func setGiftPanelVisible(_ visible: Bool, animated: Bool) {
        guard visible != giftPanelVisible else { return }
        giftPanelVisible = visible
        inputBarView.setStickerPanelVisible(visible)
        inputBarBottomConstraint?.constant = visible ? -giftPanelHeight : 0

        if visible {
            giftPanelView.isHidden = false
        }

        let animations = {
            self.giftPanelView.alpha = visible ? 1 : 0
            self.giftPanelView.transform = visible ? .identity : CGAffineTransform(translationX: 0, y: self.giftPanelHeight + 24)
            self.view.layoutIfNeeded()
        }
        let completion: (Bool) -> Void = { _ in
            if !visible {
                self.giftPanelView.isHidden = true
            }
        }

        if animated {
            UIView.animate(
                withDuration: visible ? 0.32 : 0.24,
                delay: 0,
                usingSpringWithDamping: visible ? 0.92 : 1,
                initialSpringVelocity: 0,
                options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut],
                animations: animations,
                completion: completion
            )
        } else {
            animations()
            completion(true)
        }
    }

    private func sendSticker(_ sticker: DemoSticker, from sourceFrame: CGRect) {
        playSendDropAnimation(sticker: sticker, from: sourceFrame) { [weak self] in
            guard let self else { return }
            messages.append(.gift(sticker))
            let indexPath = IndexPath(row: messages.count - 1, section: 0)
            messageTableView.insertRows(at: [indexPath], with: .automatic)
            messageTableView.scrollToRow(at: indexPath, at: .bottom, animated: true)
            updateMetrics()
        }
    }

    private func playSendDropAnimation(
        sticker: DemoSticker,
        from sourceFrame: CGRect,
        completion: @escaping () -> Void
    ) {
        let size = min(max(sourceFrame.width, 72), 104)
        let startFrame = CGRect(
            x: sourceFrame.midX - size / 2,
            y: sourceFrame.minY - 10,
            width: size,
            height: size
        )
        let targetY = min(messageTableView.frame.maxY - size - 12, view.bounds.height - size - 24)
        let targetFrame = CGRect(
            x: max(20, min(sourceFrame.midX - size / 2, view.bounds.width - size - 20)),
            y: targetY,
            width: size,
            height: size
        )

        let fallingView = TGSPlayerView(animationLoader: animationLoader)
        fallingView.frame = startFrame
        fallingView.backgroundColor = UIColor.clear
        fallingView.setup(
            source: TGSAnimatedStickerLocalFileSource(path: sticker.playbackPath),
            width: 128,
            height: 128,
            playbackMode: TGSAnimatedStickerPlaybackMode.loop,
            mode: TGSAnimatedStickerMode.cached
        )
        fallingView.overrideVisibility = true
        fallingView.visibility = true
        fallingView.autoplay = true
        view.addSubview(fallingView)

        UIView.animateKeyframes(
            withDuration: 0.62,
            delay: 0,
            options: [.calculationModeCubic, .allowUserInteraction]
        ) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.22) {
                fallingView.transform = CGAffineTransform(scaleX: 1.18, y: 1.18)
                fallingView.center.y -= 26
            }
            UIView.addKeyframe(withRelativeStartTime: 0.18, relativeDuration: 0.62) {
                fallingView.frame = targetFrame
                fallingView.transform = CGAffineTransform(scaleX: 0.62, y: 0.62)
                fallingView.alpha = 0.28
            }
        } completion: { _ in
            fallingView.reset()
            fallingView.removeFromSuperview()
            completion()
        }
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
        let bundledURLs = loadBundledTGSURLs()
        let stickers = bundledURLs
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map(DemoSticker.init(fileURL:))
        return DemoGiftCatalog(stickers: stickers)
    }

    private static func loadBundledTGSURLs() -> [URL] {
        let nestedURLs = Bundle.main.urls(forResourcesWithExtension: "tgs", subdirectory: "tgs") ?? []
        let flatURLs = Bundle.main.urls(forResourcesWithExtension: "tgs", subdirectory: nil) ?? []
        var seen = Set<String>()
        return (nestedURLs + flatURLs).filter { url in
            seen.insert(url.lastPathComponent).inserted
        }
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

private final class ChatInputBarView: UIView {
    var onTapStickerButton: (() -> Void)?

    private let stickerButton = UIButton(type: .system)
    private let inputBackgroundView = UIView()
    private let placeholderLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.09, green: 0.10, blue: 0.12, alpha: 0.98)
        configureSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func setStickerPanelVisible(_ visible: Bool) {
        let imageName = visible ? "keyboard.chevron.compact.down" : "face.smiling"
        stickerButton.setImage(UIImage(systemName: imageName), for: .normal)
        stickerButton.tintColor = visible
            ? UIColor(red: 0.29, green: 0.67, blue: 1.0, alpha: 1)
            : UIColor(white: 1, alpha: 0.78)
    }

    private func configureSubviews() {
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.2
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: -5)

        stickerButton.setImage(UIImage(systemName: "face.smiling"), for: .normal)
        stickerButton.tintColor = UIColor(white: 1, alpha: 0.78)
        stickerButton.addTarget(self, action: #selector(stickerButtonTapped), for: .touchUpInside)
        stickerButton.addTarget(self, action: #selector(stickerButtonTapped), for: .primaryActionTriggered)
        stickerButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stickerButton)

        inputBackgroundView.backgroundColor = UIColor(white: 1, alpha: 0.08)
        inputBackgroundView.layer.cornerRadius = 18
        inputBackgroundView.layer.masksToBounds = true
        inputBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(inputBackgroundView)

        placeholderLabel.text = "Message"
        placeholderLabel.font = .systemFont(ofSize: 15, weight: .regular)
        placeholderLabel.textColor = UIColor(white: 1, alpha: 0.42)
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        inputBackgroundView.addSubview(placeholderLabel)

        NSLayoutConstraint.activate([
            stickerButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stickerButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            stickerButton.widthAnchor.constraint(equalToConstant: 44),
            stickerButton.heightAnchor.constraint(equalToConstant: 44),
            inputBackgroundView.leadingAnchor.constraint(equalTo: stickerButton.trailingAnchor, constant: 4),
            inputBackgroundView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            inputBackgroundView.centerYAnchor.constraint(equalTo: centerYAnchor),
            inputBackgroundView.heightAnchor.constraint(equalToConstant: 38),
            placeholderLabel.leadingAnchor.constraint(equalTo: inputBackgroundView.leadingAnchor, constant: 14),
            placeholderLabel.trailingAnchor.constraint(equalTo: inputBackgroundView.trailingAnchor, constant: -14),
            placeholderLabel.centerYAnchor.constraint(equalTo: inputBackgroundView.centerYAnchor)
        ])
    }

    @objc private func stickerButtonTapped() {
        onTapStickerButton?()
    }
}

private final class GiftPanelView: UIView {
    var onSelectSticker: ((DemoSticker, CGRect) -> Void)?

    private let titleLabel = UILabel()
    private let layout = UICollectionViewFlowLayout()
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)

    private var stickers: [DemoSticker] = []
    private var loader: TGSLottieAnimationLoading?

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

    func configure(stickers: [DemoSticker], loader: TGSLottieAnimationLoading) {
        self.stickers = stickers
        self.loader = loader
        collectionView.reloadData()
    }

    private func configureSubviews() {
        titleLabel.text = "TGS files"
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
        cell.configure(sticker: stickers[indexPath.item], loader: loader)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let cell = collectionView.cellForItem(at: indexPath) else { return }
        let sourceFrame = cell.convert(cell.bounds, to: nil)
        onSelectSticker?(stickers[indexPath.item], sourceFrame)
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

    private let playerView = TGSPlayerView()
    private let nameLabel = UILabel()
    private let typeLabel = UILabel()
    private var source: TGSAnimatedStickerLocalFileSource?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = UIColor(white: 1, alpha: 0.08)
        contentView.layer.cornerRadius = 8
        contentView.layer.masksToBounds = true

        playerView.backgroundColor = .clear
        playerView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(playerView)

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
            playerView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            playerView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            playerView.widthAnchor.constraint(equalToConstant: 52),
            playerView.heightAnchor.constraint(equalToConstant: 52),
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            nameLabel.topAnchor.constraint(equalTo: playerView.bottomAnchor, constant: 6),
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
        playerView.reset()
        source = nil
    }

    func configure(sticker: DemoSticker, loader: TGSLottieAnimationLoading?) {
        nameLabel.text = sticker.stickerName
        typeLabel.text = "TGS"
        typeLabel.textColor = UIColor(red: 0.25, green: 0.70, blue: 1.0, alpha: 1)
        guard let loader else {
            playerView.reset()
            return
        }
        playerView.animationLoader = loader
        let source = TGSAnimatedStickerLocalFileSource(path: sticker.playbackPath)
        self.source = source
        playerView.setup(
            source: source,
            width: 96,
            height: 96,
            playbackMode: .loop,
            mode: .cached
        )
        playerView.overrideVisibility = true
        playerView.visibility = true
        playerView.autoplay = true
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
            titleLabel.text = "Send \(sticker.stickerName).tgs"
            subtitleLabel.text = "Local TGS file #\(sticker.id)"
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
