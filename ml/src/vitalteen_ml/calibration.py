"""置信度校准与评测。

**为什么这是本项目最重要的一段代码**

Laya 出厂状态的置信度不可信：中文 ECE 0.314，且第三方实测发现**答错时置信度
可达 0.91**。一个会自信地说错话的系统，用在青少年身上比一个说「我不确定」的
系统危险得多 —— 用户没有办法分辨「模型很确定」和「模型在瞎猜」。

温度校准不改变模型选了哪个选项，只改变它对自己选的那个有多确信。
因此在决策层里它是安全的：`choice` 的结果不变，变的只是我们敢不敢拿
那个置信度去做门控。

**两条必须守住的性质**

1. **校准不得改变 argmax。** 否则「校准」就变成了「改答案」，而权重并没有变 ——
   那是在用一个统计技巧掩盖模型判断，不是校准。:func:`apply_temperature`
   的实现与测试都锁住这一点。
2. **ECE 必须能识别「自信地错」。** 一个只统计平均置信度的指标看不出问题；
   ECE 按置信度分桶比较「桶内准确率」与「桶内平均置信度」，因此对
   「0.9 置信度但只有 0.5 准确率」这类失效极其敏感。

纯 numpy 实现，不引入 scipy/scikit-learn：温度拟合是一维优化、ECE 是分桶统计，
实现都很短，而每多一个依赖，租用 GPU 机器上就多一个需要对齐版本的东西。
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

_EPS = 1e-12

#: 温度的搜索范围（在对数尺度上）。下界 0.05 意味着「极度锐化」，
#: 上界 20 意味着「几乎均匀」。再往外没有实际意义，只会让拟合在极端数据上发散。
_LOG_T_RANGE = (np.log(0.05), np.log(20.0))


class CalibrationError(ValueError):
    """输入不合法（形状不符、类别越界、分桶数非法）。"""


def _validate(probabilities: np.ndarray, labels: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    probs = np.asarray(probabilities, dtype=float)
    labs = np.asarray(labels, dtype=int)
    if probs.ndim != 2:
        raise CalibrationError(f"probabilities 应为 (n, k) 的二维数组，实际 {probs.shape}")
    if labs.ndim != 1 or labs.shape[0] != probs.shape[0]:
        raise CalibrationError(
            f"labels 长度应与样本数一致：labels {labs.shape} vs probabilities {probs.shape}"
        )
    if probs.shape[0] == 0:
        raise CalibrationError("样本数为 0，无法评测")
    if probs.shape[1] < 2:
        raise CalibrationError("至少需要 2 个类别 —— 单类选择不存在「选择」这回事")
    if labs.min() < 0 or labs.max() >= probs.shape[1]:
        raise CalibrationError(f"labels 越界：取值范围应为 [0, {probs.shape[1] - 1}]")
    if not np.all(np.isfinite(probs)):
        raise CalibrationError("probabilities 含非有限值")
    if np.any(probs < 0):
        raise CalibrationError("probabilities 不能为负")
    return probs, labs


def normalize(probabilities: np.ndarray) -> np.ndarray:
    """把每行归一到和为 1。全零行退化为均匀分布，而不是产生 NaN。"""
    probs = np.asarray(probabilities, dtype=float)
    totals = probs.sum(axis=1, keepdims=True)
    safe = np.where(totals <= _EPS, 1.0, totals)
    out = probs / safe
    uniform = np.full_like(out, 1.0 / out.shape[1])
    return np.where(totals <= _EPS, uniform, out)


def top_confidence(probabilities: np.ndarray) -> np.ndarray:
    """每个样本的「置信度」= 最高那一类的概率。"""
    return normalize(probabilities).max(axis=1)


def predicted_labels(probabilities: np.ndarray) -> np.ndarray:
    """每个样本被选中的类别。

    **并列时取下标较小者** —— ``argmax`` 的默认行为，确定且可复现。
    温度校准不改变它（见 :func:`apply_temperature`）。
    """
    return normalize(probabilities).argmax(axis=1)


def correctness(probabilities: np.ndarray, labels: np.ndarray) -> np.ndarray:
    """每个样本是否答对。"""
    _, labs = _validate(probabilities, labels)
    return (predicted_labels(probabilities) == labs).astype(float)


def expected_calibration_error(
    probabilities: np.ndarray,
    labels: np.ndarray,
    *,
    n_bins: int = 15,
) -> float:
    """期望校准误差（ECE）。

    按置信度等宽分桶，对每个桶比较「桶内准确率」与「桶内平均置信度」，
    以样本占比加权求和。完美校准时为 0。

    与「平均置信度」这类粗糙指标的区别：ECE 能识别**自信地错** ——
    一个 0.9 置信度但只有 0.5 准确率的模型，其平均置信度看起来很漂亮，
    而 ECE 会把它暴露出来。这正是 Laya 出厂状态的问题所在。

    Args:
        n_bins: 分桶数。15 是常用默认；样本很少时应当调小，
            否则大部分桶是空的，ECE 会退化成噪声。
    """
    if n_bins < 1:
        raise CalibrationError(f"n_bins 必须 >= 1，实际 {n_bins}")
    probs, labs = _validate(probabilities, labels)

    confidences = top_confidence(probs)
    hits = (predicted_labels(probs) == labs).astype(float)

    # 边界放在桶中心，避免 1.0 这个值被排除在最后一个桶之外
    edges = np.linspace(0.0, 1.0, n_bins + 1)
    total = len(confidences)
    ece = 0.0
    for index in range(n_bins):
        low, high = edges[index], edges[index + 1]
        # 最后一个桶闭区间，否则置信度恰好为 1.0 的样本会被丢掉
        in_bin = (
            (confidences > low) & (confidences <= high)
            if index > 0
            else (confidences >= low) & (confidences <= high)
        )
        count = int(in_bin.sum())
        if count == 0:
            continue
        gap = abs(hits[in_bin].mean() - confidences[in_bin].mean())
        ece += (count / total) * gap
    return float(ece)


def apply_temperature(probabilities: np.ndarray, temperature: float) -> np.ndarray:
    """按温度缩放概率。

    ``p' ∝ p ** (1 / T)``。

    - ``T > 1`` 软化分布（降低置信度）
    - ``T < 1`` 锐化分布（提高置信度）
    - ``T = 1`` 恒等

    **不改变 argmax。** ``x ** (1/T)`` 在 ``T > 0`` 时是单调递增的，
    因此每一类的相对次序不变。这条性质由测试锁死 —— 校准若改了答案，
    那就不是校准，而是用一个统计技巧掩盖模型的判断。
    """
    if not np.isfinite(temperature) or temperature <= 0:
        raise CalibrationError(f"temperature 必须为正的有限值，实际 {temperature}")
    probs = normalize(probabilities)
    scaled = np.power(np.clip(probs, _EPS, None), 1.0 / temperature)
    return normalize(scaled)


def negative_log_likelihood(probabilities: np.ndarray, labels: np.ndarray) -> float:
    """正确类别的平均负对数似然。温度拟合的目标函数。"""
    probs, labs = _validate(probabilities, labels)
    picked = normalize(probs)[np.arange(len(labs)), labs]
    return float(-np.mean(np.log(np.clip(picked, _EPS, None))))


@dataclass(frozen=True, slots=True)
class TemperatureFit:
    """温度拟合的结果。"""

    temperature: float
    nll_before: float
    nll_after: float
    converged: bool

    @property
    def improvement(self) -> float:
        """NLL 的下降量。为 0 表示数据本来就已校准好。"""
        return self.nll_before - self.nll_after


def fit_temperature(
    probabilities: np.ndarray,
    labels: np.ndarray,
    *,
    tolerance: float = 1e-6,
    max_iterations: int = 200,
) -> TemperatureFit:
    """在留出集上拟合温度，最小化正确类别的负对数似然。

    **必须用留出集（calib split），不能用训练集。** 在训练集上拟合出的温度会
    过拟合到那批样本，换到测试集上校准效果大打折扣 —— 这是校准文献里最常被
    忽略的一条实践。

    用黄金分割法在 ``log(T)`` 上做一维搜索：NLL 关于 log(T) 是单峰的
    （指数族的标准结论），因此不需要导数也不需要多次随机重启。

    Args:
        tolerance: 搜索区间的收敛容差（在 log 尺度上）。
        max_iterations: 迭代上限，防止极端数据下不收敛。
    """
    probs, labs = _validate(probabilities, labels)

    def nll_at(log_temperature: float) -> float:
        temperature = float(np.exp(log_temperature))
        return negative_log_likelihood(apply_temperature(probs, temperature), labs)

    lo, hi = _LOG_T_RANGE
    phi = (np.sqrt(5.0) - 1.0) / 2.0
    x1, x2 = hi - phi * (hi - lo), lo + phi * (hi - lo)
    f1, f2 = nll_at(x1), nll_at(x2)

    converged = False
    for _ in range(max_iterations):
        if hi - lo < tolerance:
            converged = True
            break
        if f1 < f2:
            hi, x2, f2 = x2, x1, f1
            x1 = hi - phi * (hi - lo)
            f1 = nll_at(x1)
        else:
            lo, x1, f1 = x1, x2, f2
            x2 = lo + phi * (hi - lo)
            f2 = nll_at(x2)

    best_log_t = (lo + hi) / 2.0
    nll_before = nll_at(0.0)  # T = 1 即未校准
    nll_after = nll_at(best_log_t)

    # 拟合不出改善时返回恒等变换，而不是一个更差的温度 ——
    # 「校准后反而更差」不该发生，但它能发生，就必须让它倾向于不发生。
    if nll_after > nll_before:
        return TemperatureFit(
            temperature=1.0, nll_before=nll_before, nll_after=nll_before, converged=converged
        )
    return TemperatureFit(
        temperature=float(np.exp(best_log_t)),
        nll_before=nll_before,
        nll_after=nll_after,
        converged=converged,
    )


@dataclass(frozen=True, slots=True)
class Evaluation:
    """一份预测的评测结果。"""

    label: str
    n: int
    accuracy: float
    ece: float
    mean_confidence: float
    nll: float


def evaluate(
    probabilities: np.ndarray,
    labels: np.ndarray,
    *,
    label: str = "model",
    n_bins: int = 15,
) -> Evaluation:
    """一次完整评测。"""
    probs, labs = _validate(probabilities, labels)
    return Evaluation(
        label=label,
        n=len(labs),
        accuracy=float(correctness(probs, labs).mean()),
        ece=expected_calibration_error(probs, labs, n_bins=n_bins),
        mean_confidence=float(top_confidence(probs).mean()),
        nll=negative_log_likelihood(probs, labs),
    )


def comparison_table(evaluations: list[Evaluation]) -> str:
    """把若干次评测渲染成三栏对比表。

    计划书要求的「基线 / 微调 / 微调+校准」对比就是它。渲染成文本而不是
    DataFrame 是为了能在没有 pandas 的环境里跑（GPU 机器上只有 numpy）。
    """
    if not evaluations:
        return "（无评测结果）"
    width = max(len(item.label) for item in evaluations)
    header = f"{'配置'.ljust(width)}  样本数   准确率      ECE   平均置信度      NLL"
    lines = [header, "-" * len(header)]
    for item in evaluations:
        lines.append(
            f"{item.label.ljust(width)}  {item.n:>6}  "
            f"{item.accuracy:>7.4f}  {item.ece:>7.4f}  "
            f"{item.mean_confidence:>9.4f}  {item.nll:>7.4f}"
        )
    return "\n".join(lines)


__all__ = [
    "CalibrationError",
    "Evaluation",
    "TemperatureFit",
    "apply_temperature",
    "comparison_table",
    "correctness",
    "evaluate",
    "expected_calibration_error",
    "fit_temperature",
    "negative_log_likelihood",
    "normalize",
    "predicted_labels",
    "top_confidence",
]
