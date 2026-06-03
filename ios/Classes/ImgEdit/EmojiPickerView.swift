import Flutter
import UIKit

/// PlatformView `loopit/minis/emoji_picker`. Native emoji grid backed by
/// `UICollectionView` + `UISegmentedControl`. Selections emit through the
/// `loopit/minis/emoji_picker/selected` MethodChannel as
/// `emit({codePoint: Int})`.
public final class EmojiPickerViewFactory: NSObject, FlutterPlatformViewFactory {
    private let messenger: FlutterBinaryMessenger

    public init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
    }

    public func create(
        withFrame frame: CGRect, viewIdentifier viewId: Int64,
        arguments args: Any?
    ) -> FlutterPlatformView {
        return EmojiPickerPlatformView(frame: frame, viewId: viewId,
                                       messenger: messenger)
    }
}

private final class EmojiPickerPlatformView: NSObject, FlutterPlatformView,
                                              UICollectionViewDataSource,
                                              UICollectionViewDelegate {
    private let root: UIView
    private let collection: UICollectionView
    private let segment: UISegmentedControl
    private let channel: FlutterMethodChannel
    private var current: [Int] = EmojiPickerPlatformView.categories[0].codepoints

    private static let categories: [(label: String, key: String, codepoints: [Int])] = [
        ("Recent",  "recent",  []),
        ("Smiles",  "smileys", Array(0x1F600...0x1F64F)),
        ("Animals", "animals", Array(0x1F400...0x1F43E)),
        ("Food",    "food",    Array(0x1F32D...0x1F37F)),
        ("Travel",  "travel",  Array(0x1F680...0x1F6C5)),
        ("Objects", "objects", Array(0x1F4A0...0x1F4FF)),
        ("Symbols", "symbols", Array(0x2700...0x27BF)),
        ("Flags",   "flags",   Array(0x1F1E6...0x1F1FF)),
    ]
    private static let recentsKey = "minis_emoji_recents"

    init(frame: CGRect, viewId: Int64, messenger: FlutterBinaryMessenger) {
        self.root = UIView(frame: frame)
        let layout = UICollectionViewFlowLayout()
        layout.itemSize = CGSize(width: 44, height: 44)
        layout.minimumInteritemSpacing = 4
        layout.minimumLineSpacing = 4
        self.collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        self.segment = UISegmentedControl(items: EmojiPickerPlatformView
            .categories.map { $0.label })
        self.channel = FlutterMethodChannel(
            name: "loopit/minis/emoji_picker/selected",
            binaryMessenger: messenger)
        super.init()
        setup()
    }

    private func setup() {
        root.backgroundColor = UIColor(red: 0.06, green: 0.06, blue: 0.06, alpha: 1)
        segment.translatesAutoresizingMaskIntoConstraints = false
        segment.selectedSegmentIndex = 1
        segment.addTarget(self, action: #selector(onSegment(_:)),
                          for: .valueChanged)
        root.addSubview(segment)
        current = EmojiPickerPlatformView.categories[1].codepoints
        collection.translatesAutoresizingMaskIntoConstraints = false
        collection.backgroundColor = .clear
        collection.register(EmojiCell.self, forCellWithReuseIdentifier: "c")
        collection.dataSource = self
        collection.delegate = self
        root.addSubview(collection)

        NSLayoutConstraint.activate([
            segment.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 8),
            segment.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            segment.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            collection.topAnchor.constraint(equalTo: segment.bottomAnchor, constant: 8),
            collection.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            collection.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            collection.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
    }

    @objc private func onSegment(_ s: UISegmentedControl) {
        let i = s.selectedSegmentIndex
        let cat = EmojiPickerPlatformView.categories[i]
        current = cat.key == "recent" ? loadRecents() : cat.codepoints
        collection.reloadData()
    }

    func view() -> UIView { root }

    func collectionView(_ collectionView: UICollectionView,
                        numberOfItemsInSection section: Int) -> Int {
        return current.count
    }

    func collectionView(_ collectionView: UICollectionView,
                        cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "c",
                                                      for: indexPath) as! EmojiCell
        let cp = current[indexPath.item]
        if let scalar = Unicode.Scalar(cp) {
            cell.label.text = String(scalar)
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView,
                        didSelectItemAt indexPath: IndexPath) {
        let cp = current[indexPath.item]
        channel.invokeMethod("emit", arguments: ["codePoint": cp])
        appendRecent(cp)
    }

    private func loadRecents() -> [Int] {
        let s = UserDefaults.standard.string(forKey: EmojiPickerPlatformView.recentsKey) ?? ""
        return s.split(separator: ",").compactMap { Int($0) }
    }

    private func appendRecent(_ cp: Int) {
        var cur = loadRecents()
        cur.removeAll(where: { $0 == cp })
        cur.insert(cp, at: 0)
        if cur.count > 32 { cur = Array(cur.prefix(32)) }
        UserDefaults.standard.set(cur.map { String($0) }.joined(separator: ","),
                                  forKey: EmojiPickerPlatformView.recentsKey)
    }
}

private final class EmojiCell: UICollectionViewCell {
    let label: UILabel = UILabel()
    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 32)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: contentView.topAnchor),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}
