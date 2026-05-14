import Darwin
import TGSPlayerKit
import UIKit

final class DemoViewController: UIViewController {
    private struct StressProfile {
        let title: String
        let itemCount: Int
        let columns: Int
    }

    private let stressProfiles: [StressProfile] = [
        StressProfile(title: "24", itemCount: 24, columns: 4),
        StressProfile(title: "60", itemCount: 60, columns: 6),
        StressProfile(title: "120", itemCount: 120, columns: 8)
    ]

    private let animationLoader = TGSRLottieAnimationLoader()
    private let metricsView = PerformanceMetricsView()
    private let profileControl = UISegmentedControl(items: ["24", "60", "120"])
    private let pauseButton = UIButton(type: .system)
    private let layout = UICollectionViewFlowLayout()
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)

    private var displayLink: CADisplayLink?
    private var lastDisplayTimestamp: CFTimeInterval = 0
    private var lastMetricsTimestamp: CFTimeInterval = 0
    private var fpsSamples: [Double] = []
    private var frameCallbackCount: Int = 0
    private var selectedProfileIndex: Int = 1
    private var isPaused: Bool = false

    private var samplePath: String {
        guard let path = Bundle.main.path(forResource: "sample_pulse", ofType: "json") else {
            preconditionFailure("Missing sample_pulse.json")
        }
        return path
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.06, green: 0.07, blue: 0.08, alpha: 1.0)
        configureControls()
        configureCollectionView()
        startMetricsDisplayLink()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layout.itemSize = itemSize()
        layout.invalidateLayout()
    }

    deinit {
        displayLink?.invalidate()
    }

    private func configureControls() {
        profileControl.selectedSegmentIndex = selectedProfileIndex
        profileControl.addTarget(self, action: #selector(profileChanged), for: .valueChanged)

        pauseButton.setTitle("Pause", for: .normal)
        pauseButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        pauseButton.tintColor = .white
        pauseButton.addTarget(self, action: #selector(togglePause), for: .touchUpInside)

        let controls = UIStackView(arrangedSubviews: [profileControl, pauseButton])
        controls.axis = .horizontal
        controls.spacing = 12
        controls.alignment = .center
        controls.distribution = .fill

        profileControl.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pauseButton.setContentHuggingPriority(.required, for: .horizontal)

        let header = UIStackView(arrangedSubviews: [metricsView, controls])
        header.axis = .vertical
        header.spacing = 12
        header.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12)
        ])
    }

    private func configureCollectionView() {
        layout.minimumLineSpacing = 8
        layout.minimumInteritemSpacing = 8
        layout.sectionInset = UIEdgeInsets(top: 12, left: 12, bottom: 24, right: 12)

        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(StickerCell.self, forCellWithReuseIdentifier: StickerCell.reuseIdentifier)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.alwaysBounceVertical = true
        collectionView.showsVerticalScrollIndicator = false

        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: profileControl.bottomAnchor, constant: 12),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func startMetricsDisplayLink() {
        let displayLink = CADisplayLink(target: self, selector: #selector(displayLinkDidTick(_:)))
        displayLink.preferredFramesPerSecond = 60
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }

    private func itemSize() -> CGSize {
        let profile = stressProfiles[selectedProfileIndex]
        let horizontalInset = layout.sectionInset.left + layout.sectionInset.right
        let spacing = CGFloat(profile.columns - 1) * layout.minimumInteritemSpacing
        let availableWidth = max(1, collectionView.bounds.width - horizontalInset - spacing)
        let width = floor(availableWidth / CGFloat(profile.columns))
        return CGSize(width: max(40, width), height: max(40, width))
    }

    private func restartVisiblePlayers() {
        for cell in collectionView.visibleCells {
            (cell as? StickerCell)?.setPaused(isPaused)
        }
    }

    @objc private func profileChanged() {
        selectedProfileIndex = max(0, profileControl.selectedSegmentIndex)
        frameCallbackCount = 0
        fpsSamples.removeAll(keepingCapacity: true)
        layout.itemSize = itemSize()
        collectionView.reloadData()
    }

    @objc private func togglePause() {
        isPaused.toggle()
        pauseButton.setTitle(isPaused ? "Resume" : "Pause", for: .normal)
        restartVisiblePlayers()
    }

    @objc private func displayLinkDidTick(_ link: CADisplayLink) {
        if lastDisplayTimestamp > 0 {
            let delta = link.timestamp - lastDisplayTimestamp
            if delta > 0 {
                fpsSamples.append(1.0 / delta)
            }
        }
        lastDisplayTimestamp = link.timestamp

        guard link.timestamp - lastMetricsTimestamp >= 1.0 else {
            return
        }

        let averageFPS = fpsSamples.isEmpty ? 0 : fpsSamples.reduce(0, +) / Double(fpsSamples.count)
        let profile = stressProfiles[selectedProfileIndex]
        metricsView.update(
            fps: averageFPS,
            framesPerSecond: frameCallbackCount,
            visiblePlayers: collectionView.visibleCells.count,
            totalPlayers: profile.itemCount,
            memoryMB: residentMemoryMB()
        )
        frameCallbackCount = 0
        fpsSamples.removeAll(keepingCapacity: true)
        lastMetricsTimestamp = link.timestamp
    }

    private func residentMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.stride / MemoryLayout<natural_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return 0
        }
        return Double(info.resident_size) / 1_048_576.0
    }
}

extension DemoViewController: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        stressProfiles[selectedProfileIndex].itemCount
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: StickerCell.reuseIdentifier,
            for: indexPath
        ) as! StickerCell
        cell.configure(
            path: samplePath,
            loader: animationLoader,
            paused: isPaused
        ) { [weak self] in
            self?.frameCallbackCount += 1
        }
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        itemSize()
    }
}

private final class StickerCell: UICollectionViewCell {
    static let reuseIdentifier = "StickerCell"

    private let playerView = TGSPlayerView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = UIColor(white: 0.92, alpha: 1.0)
        contentView.layer.cornerRadius = 8
        contentView.layer.masksToBounds = true
        playerView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(playerView)
        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            playerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        playerView.frameUpdated = { _, _ in }
        playerView.reset()
    }

    func configure(
        path: String,
        loader: TGSLottieAnimationLoading,
        paused: Bool,
        onFrame: @escaping () -> Void
    ) {
        playerView.animationLoader = loader
        playerView.frameUpdated = { _, _ in onFrame() }
        playerView.setup(
            source: TGSAnimatedStickerLocalFileSource(path: path),
            width: 96,
            height: 96,
            playbackMode: .loop,
            mode: .direct(cachePathPrefix: nil)
        )
        playerView.overrideVisibility = true
        playerView.visibility = !paused
        playerView.autoplay = !paused
    }

    func setPaused(_ paused: Bool) {
        playerView.visibility = !paused
        playerView.autoplay = !paused
    }
}

private final class PerformanceMetricsView: UIView {
    private let titleLabel = UILabel()
    private let fpsLabel = UILabel()
    private let framesLabel = UILabel()
    private let playersLabel = UILabel()
    private let memoryLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 1.0, alpha: 0.08)
        layer.cornerRadius = 8
        layer.masksToBounds = true

        titleLabel.text = "TGSPlayerKit rlottie stress"
        titleLabel.font = .systemFont(ofSize: 17, weight: .bold)
        titleLabel.textColor = .white

        let row = UIStackView(arrangedSubviews: [fpsLabel, framesLabel, playersLabel, memoryLabel])
        row.axis = .horizontal
        row.spacing = 10
        row.distribution = .fillEqually

        let stack = UIStackView(arrangedSubviews: [titleLabel, row])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
        ])

        [fpsLabel, framesLabel, playersLabel, memoryLabel].forEach {
            $0.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            $0.textColor = UIColor(white: 1.0, alpha: 0.86)
            $0.adjustsFontSizeToFitWidth = true
            $0.minimumScaleFactor = 0.72
        }
        update(fps: 0, framesPerSecond: 0, visiblePlayers: 0, totalPlayers: 0, memoryMB: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func update(
        fps: Double,
        framesPerSecond: Int,
        visiblePlayers: Int,
        totalPlayers: Int,
        memoryMB: Double
    ) {
        fpsLabel.text = String(format: "FPS %.1f", fps)
        framesLabel.text = "\(framesPerSecond) frames/sec"
        playersLabel.text = "\(visiblePlayers)/\(totalPlayers) visible"
        memoryLabel.text = String(format: "%.0f MB", memoryMB)
    }
}
