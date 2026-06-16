import Foundation

struct DrinkLabelData {
    var brand = ""
    var name = ""
    var sweetness = ""
    var iceLevel = ""
    var nameCandidates: [String] = []
    var didRecognizeUsefulInformation = false
}

enum DrinkLabelParser {
    private static let sweetnessTerms = [
        "全糖", "正常糖", "少糖", "七分糖", "半糖", "五分糖", "三分糖", "微糖", "一分糖", "无糖", "不另外加糖"
    ]
    private static let iceTerms = [
        "正常冰", "标准冰", "多冰", "少冰", "微冰", "去冰", "不加冰", "常温", "温热", "温饮", "热饮"
    ]
    private static let noiseTerms = [
        "订单", "取餐", "单号", "电话", "门店", "地址", "时间", "合计", "实付", "小计", "备注", "谢谢",
        "外卖", "自取", "杯", "￥", "¥", "配料", "加料", "吸管", "小票", "发票", "支付", "配送"
    ]

    static func parse(_ lines: [String], knownBrands: [String]) -> DrinkLabelData {
        let cleaned = lines.map(clean).filter { !$0.isEmpty }
        var result = DrinkLabelData()

        result.brand = firstKnownBrand(in: cleaned, knownBrands: knownBrands)
        result.sweetness = firstTerm(in: cleaned, candidates: sweetnessTerms)
        result.iceLevel = firstIceTerm(in: cleaned)

        let candidates = cleaned.filter { line in
            !noiseTerms.contains(where: line.contains)
                && !sweetnessTerms.contains(where: line.contains)
                && !iceTerms.contains(where: line.contains)
                && !line.contains("糖")
                && !line.contains("冰")
                && !line.matches(#"^\d{1,4}[-/:.]\d{1,2}"#)
                && !line.matches(#"^[\d\s\-+()]{6,}$"#)
                && !line.matches(#"^[A-Z0-9]{5,}$"#)
                && line.count >= 2
                && line.count <= 18
        }

        if let explicitName = value(after: ["品名", "饮品", "商品", "name"], in: candidates) {
            result.name = explicitName
        }

        let unlabeled = candidates.filter {
            !containsPrefix($0, prefixes: ["品牌", "brand", "品名", "饮品", "商品", "name"])
        }
        result.nameCandidates = unique(unlabeled.filter(isLikelyDrinkName))
        if result.name.isEmpty {
            result.name = result.nameCandidates.first ?? ""
        }

        result.didRecognizeUsefulInformation = !result.brand.isEmpty
            || !result.name.isEmpty
            || !result.sweetness.isEmpty
            || !result.iceLevel.isEmpty
        return result
    }

    private static func clean(_ value: String) -> String {
        value
            .replacingOccurrences(of: "：", with: ":")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstTerm(in lines: [String], candidates: [String]) -> String {
        for line in lines {
            if let term = candidates.first(where: line.contains) {
                return term
            }
        }
        return ""
    }

    private static func firstIceTerm(in lines: [String]) -> String {
        for line in lines {
            if line.contains("去冰") || line.contains("不加冰") { return "去冰" }
            if line.contains("微冰") { return "微冰" }
            if line.contains("少冰") { return "少冰" }
            if line.contains("多冰") { return "多冰" }
            if line.contains("正常冰") || line.contains("标准冰") { return "正常冰" }
            if line.contains("常温") { return "常温" }
            if line.contains("温热") || line.contains("温饮") { return "温" }
            if line.contains("热饮") { return "热" }
        }
        return ""
    }

    private static func firstKnownBrand(in lines: [String], knownBrands: [String]) -> String {
        for line in lines {
            if let brand = knownBrands.first(where: { line.localizedCaseInsensitiveContains($0) }) {
                return brand
            }
        }
        return ""
    }

    private static func value(after keys: [String], in lines: [String]) -> String? {
        for line in lines {
            let lowered = line.lowercased()
            for key in keys where lowered.hasPrefix(key.lowercased()) {
                let value = line.dropFirst(key.count)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ":- "))
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    private static func containsPrefix(_ line: String, prefixes: [String]) -> Bool {
        prefixes.contains { line.lowercased().hasPrefix($0.lowercased()) }
    }

    private static func isLikelyDrinkName(_ line: String) -> Bool {
        let keywords = ["茶", "奶", "拿铁", "咖啡", "椰", "芝士", "波波", "珍珠", "乌龙", "茉莉", "柠檬", "果", "雪顶"]
        return keywords.contains(where: line.contains) || line.count > 5
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

private extension String {
    func matches(_ pattern: String) -> Bool {
        range(of: pattern, options: .regularExpression) != nil
    }
}
