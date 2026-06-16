import Foundation

enum BrandStore {
    static let commonBrands = [
        "喜茶", "奈雪的茶", "霸王茶姬", "茶百道", "古茗", "沪上阿姨", "一点点", "CoCo都可",
        "蜜雪冰城", "书亦烧仙草", "乐乐茶", "LINLEE", "柠季", "茶颜悦色", "爷爷不泡茶",
        "茉莉奶白", "快乐柠檬", "益禾堂", "贡茶", "KOI", "百分茶", "阿嬷手作", "伏见桃山",
        "瑞幸咖啡", "M Stand", "Manner", "星巴克"
    ]

    private static let recentBrandsKey = "recentBrands"

    static var allKnownBrands: [String] {
        unique(recentBrands + commonBrands)
    }

    static var recentBrands: [String] {
        UserDefaults.standard.stringArray(forKey: recentBrandsKey) ?? []
    }

    static func remember(_ brand: String) {
        let cleaned = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let updated = unique([cleaned] + recentBrands).prefix(12)
        UserDefaults.standard.set(Array(updated), forKey: recentBrandsKey)
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
