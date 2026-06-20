# 会不会喝评分算法

本文档记录 MilkTCompendium v1 的“会不会喝”评分口径。代码实现应与本文档保持一致。

## 输出

算法输出一个 `0...5` 的数字，表示一个人的奶茶图鉴见识、评分可靠度和与他人评分画像的合意程度。UI 显示为两位小数，例如 `会喝 3.42`。

先计算原始能力值：

```text
rawAbility =
  totalCupComponent * 0.38 +
  exchangeComponent * 0.32 +
  agreementComponent * 0.15 +
  authorityComponent * 0.15
```

再将原始能力值校准为 `0...5` 的近似正态分数：

```text
boundedAbility = min(max(rawAbility, 0.001), 0.999)
logitAbility = log(boundedAbility / (1 - boundedAbility))
zScore = (logitAbility - 0.925871272) / 0.564801108
score = min(max(2.5 + zScore * 1.1, 0), 5)
```

校准常数来自 100000 个理想状态模拟用户。理想状态模拟假设：

- 本地杯数为右偏分布，群体平均值为 `50` 杯。
- 成功交换次数为右偏分布，群体平均值为 `20` 次。
- 同一个人可能重复交换；去重后的交换对象数按成功交换次数的约 `60%` 模拟，并且不超过成功交换次数。
- 每个去重交换对象的最新图鉴杯数也为右偏分布，群体平均值为 `50` 杯。
- 合意度来自偏高但非满分的混合 beta 分布。
- 本地均分围绕 `2.5` 波动，杯数越多均分波动越小。

新模拟口径下的关键分位数：

```text
localDrinkCount: mean 50.02, median 42, p90 97, p95 118, p99 165
successfulExchangeCount: mean 20.00, median 17, p90 39, p95 47, p99 67
uniquePeerCount: mean 11.99, median 10, p90 24, p95 30, p99 42
totalCupCount: mean 649.48, median 537, p90 1264, p95 1561, p99 2223
```

因此 v1 使用接近 p99 的 `totalCupCeiling = 2200` 和 `exchangeCeiling = 70`。这两个值是 log 归一化尺度，不是硬性上限；超过尺度后分项封顶为 `1`。

当前校准下，100000 个理想样本的验算结果：

```text
mean = 2.498
standardDeviation = 1.061
score bins [0...1, 1...2, 2...3, 3...4, 4...5]
= [8429, 22838, 37508, 23179, 8046]
```

这让理想状态下的用户分数围绕 `2.5` 呈钟形分布，并保留 `0...5` 的边界。

## 等级名称

分数对应的等级名称如下。区间采用左闭右开，`5.00` 归入 `4...5`。

| 分数区间 | 名称 |
| --- | --- |
| `0...1` | 不在茶区 |
| `1...2` | 味觉待机 |
| `2...3` | 微糖校准 |
| `3...4` | 暗号已通 |
| `4...5` | 茶眼 |

## 输入参数

### 1. 双向成功交换次数

只统计近场互传中的成功事件：

- 发送图鉴成功：计 1 次。
- 接收图鉴并成功导入：计 1 次。
- AirDrop/系统分享不计入，因为没有可靠的成功回调。

归一化：

```text
exchangeComponent = min(log1p(successfulExchangeCount) / log1p(70), 1)
```

### 2. 合意度

合意度描述自己的评分和交换对象评分是否互相合意。它使用混合算法：

- 共同饮品匹配占 70%。
- 共同品牌均分匹配占 30%。

共同饮品定义为规范化后品牌和品名都相同。共同品牌定义为规范化后品牌相同。

单个评分差转换为相似度：

```text
similarity = max(0, 1 - abs(localRating - peerRating) / 5)
```

共同饮品匹配为所有共同饮品 similarity 的平均值。共同品牌匹配为所有共同品牌均分 similarity 的平均值。

边界：

- 如果共同饮品和共同品牌都没有样本，UI 显示 `不可用`，算法内部使用 `agreementComponent = 0.1` 作为惩罚。
- 如果只有共同饮品，使用共同饮品匹配。
- 如果只有共同品牌，使用共同品牌匹配。
- 如果两者都有，使用 `drinkMatch * 0.7 + brandMatch * 0.3`。

### 3. 权威程度

权威程度是相对指标，不代表“给低分就权威”。一个更权威的图鉴应该同时满足：

- 本地记录杯数更多，样本更稳定。
- 本地均分更接近 `2.5`，而不是整体偏宽松或整体偏苛刻。

该分项对少于 50 杯的图鉴设置额外上限；达到 50 杯后不再设置人工上限。

```text
sampleConfidence = 1 - exp(-localDrinkCount / 36)
centeredness = exp(-((localAverage - 2.5) / 1.18)^2)
rawAuthority = sampleConfidence * centeredness

if localDrinkCount < 50:
  lowCountCap = 0.50 + (localDrinkCount / 50)^0.72 * 0.50
else:
  lowCountCap = 1

authorityComponent = min(rawAuthority, lowCountCap)
```

空图鉴时使用低中性值：

```text
authorityComponent = 0.28
```

低杯数上限用于避免少量样本因为均分接近 `2.5` 而显得过度权威。少于 50 杯时，上限从 `0.50` 平滑增长到接近 `1.00`；达到 50 杯后，不再设置额外上限。

### 4. 去重历史总杯数

总杯数按：

```text
localDrinkCount + sum(latestPeerDrinkCount by ownerID)
```

同一个 `ownerID` 多次交换时：

- 成功交换次数继续累加。
- 对方杯数只保留最新快照，不重复累加。
- 对方评分画像只保留最新可用快照。

归一化：

```text
totalCupComponent = min(log1p(totalCupCount) / log1p(2200), 1)
```

## 本地统计数据

本地保存一个 JSON 统计文件，记录：

- `successfulExchangeCount`
- 每个历史交换对象的最新快照：
  - `ownerID`
  - `ownerName`
  - `drinkCount`
  - `averageRating`
  - `lastExchangedAt`
  - 轻量评分画像：品牌、品名、评分

评分画像只用于本机算法，不修改 `.mtcpack` 公开格式，也不替代完整共享图鉴。
