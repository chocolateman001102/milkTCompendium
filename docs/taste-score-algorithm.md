# 会不会喝评分算法

本文档记录 MilkTCompendium v1 的“会不会喝”评分口径。代码实现应与本文档保持一致。

## 输出

算法输出一个 `0...5` 的数字，表示一个人的奶茶图鉴见识、评分可靠度和与他人评分画像的合意程度。UI 显示为两位小数，例如 `会喝 3.42`。

v1.1 不再使用旧版 logit 校准映射。算法把每个分项转换成围绕平均画像的正负信号，再直接加权到 `0...5` 分数上：

```text
weightedSignal =
  totalCupSignal * 0.34 +
  exchangeSignal * 0.26 +
  agreementSignal * 0.17 +
  authoritySignal * 0.23

score = min(max(2.46 + weightedSignal * 2.0, 0), 5)
```

合意和权威 signal 限制在 `-2.4...2.4`。总杯数和交换次数的负向下限更温和，分别为 `-1.2` 和 `-1.0`，避免无交换用户被双重惩罚到 `0`。分项值仍是 `0...1` 值；分数计算使用中心化 signal。

中心化参数：

```text
totalCupCenter = 350
totalCupLogSpread = 0.62
exchangeCenter = 10
exchangeSpread = 4.2
agreementCenter = 0.68
agreementSpread = 0.15
authorityCenter = 0.66
authoritySpread = 0.17
```

这些参数来自 100000 个模拟用户。模拟假设：

- 本地有效收集饮品数服从截断正态分布，群体平均值为 `50`，标准差为 `15`。
- 成功交换次数服从截断正态分布，群体平均值为 `10`，标准差为 `4`。
- 同一个人可能重复交换；去重后的交换对象数按成功交换次数的约 `60%` 模拟，并且不超过成功交换次数。
- 每个去重交换对象的最新图鉴有效杯数也服从截断正态分布，群体平均值为 `50`，标准差为 `15`。
- 合意度围绕 `0.68` 波动，标准差为 `0.13`。
- 本地均分围绕 `3.0` 波动，杯数越多均分波动越小。

当前模拟口径下的关键均值：

```text
localEffectiveCupCount: mean 50.0
successfulExchangeCount: mean 10.0
totalCupCount: mean 350.0
```

当前参数下，100000 个模拟样本的验算结果：

```text
mean = 2.562
standardDeviation = 0.938
score bins [0...1, 1...2, 2...3, 3...4, 4...5]
= [4.4%, 24.5%, 37.6%, 27.2%, 6.2%]
```

这让平均画像用户围绕 `2.5` 形成钟形分布，并保留少量高低极端档位。

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

分数计算使用中心化 signal；分项值由 signal 映射为 `0...1`：

```text
exchangeSignal = clamp((successfulExchangeCount - 10) / 4.2, -1.0, 2.4)
exchangeComponent = clamp(0.5 + exchangeSignal / 4.8, 0, 1)
```

没有交换会扣分，但不会让会喝指数必然归零。

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

- 如果共同饮品和共同品牌都没有样本，算法内部使用 `agreementComponent = 0.1` 记录缺样本状态。
- 如果只有共同饮品，使用共同饮品匹配。
- 如果只有共同品牌，使用共同品牌匹配。
- 如果两者都有，使用 `drinkMatch * 0.7 + brandMatch * 0.3`。

分数计算使用：

```text
agreementSignal = clamp((agreementComponent - 0.68) / 0.15, -2.4, 2.4)
```

如果没有共同样本，总分计算使用固定 `agreementSignal = -0.5`，而不是把 `0.1` 当成真实低合意度直接打分。

### 3. 权威程度

权威程度是相对指标，不代表“给低分就权威”。一个更权威的图鉴应该同时满足：

- 本地有效杯数更多，样本更稳定。
- 本地均分更接近 `3.0`，而不是整体偏宽松或整体偏苛刻。

该分项对少于 50 有效杯的图鉴设置额外上限；达到 50 有效杯后不再设置人工上限。

```text
sampleConfidence = 1 - exp(-localEffectiveCupCount / 36)
centeredness = exp(-((localAverage - 3.0) / 1.05)^2)
rawAuthority = sampleConfidence * centeredness

if localEffectiveCupCount < 50:
  lowCountCap = 0.50 + (localEffectiveCupCount / 50)^0.72 * 0.50
else:
  lowCountCap = 1

authorityComponent = min(rawAuthority, lowCountCap)
```

空图鉴时使用低中性值：

```text
authorityComponent = 0.28
```

低杯数上限用于避免少量样本因为均分接近 `3.0` 而显得过度权威。少于 50 有效杯时，上限从 `0.50` 平滑增长到接近 `1.00`；达到 50 有效杯后，不再设置额外上限。

分数计算使用：

```text
authoritySignal = clamp((authorityComponent - 0.66) / 0.17, -2.4, 2.4)
```

### 4. 去重历史总杯数

每条饮品记录保存真实喝过杯数 `cupCount`，但 profile 和算法中的总杯数使用递减有效杯数，避免同一饮品反复喝过多次后完全压过图鉴广度。

单条饮品的有效杯数按三角递增阈值计算：

```text
effectiveCupContribution = floor((sqrt(8 * cupCount + 1) - 1) / 2)
```

含义：

- 第 1 杯计 1 有效杯。
- 第 2 到 3 杯再计 1 有效杯。
- 第 4 到 6 杯再计 1 有效杯。
- 后续以“再喝 4 杯、再喝 5 杯……”各增加 1 有效杯。

总杯数按：

```text
localEffectiveCupCount + sum(latestPeerEffectiveCupCount by ownerID)
```

同一个 `ownerID` 多次交换时：

- 成功交换次数继续累加。
- 对方有效杯数只保留最新快照，不重复累加。
- 对方评分画像只保留最新可用快照。

归一化：

```text
totalCupSignal = clamp((log1p(totalCupCount) - log1p(350)) / 0.62, -1.2, 2.4)
totalCupComponent = clamp(0.5 + totalCupSignal / 4.8, 0, 1)
```

## 本地统计数据

本地保存一个 JSON 统计文件，记录：

- `successfulExchangeCount`
- 每个历史交换对象的最新快照：
  - `ownerID`
  - `ownerName`
  - `drinkCount`，含义为该对象最新快照的有效杯数
  - `averageRating`
  - `lastExchangedAt`
  - 轻量评分画像：品牌、品名、评分、真实喝过杯数

评分画像只用于本机算法；`.mtcpack` v3 会携带每条饮品的 `cupCount`，旧包未携带时按 `1` 杯兼容。
