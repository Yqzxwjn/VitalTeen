"""置信度校准与评测测试。

这是**测量工具**的测试，因此标准比一般功能测试更高：一个坏掉的测量工具比没有
工具更糟 —— 它会让团队对一次失败的微调产生成功的错觉。

其中两条断言是整套东西的立身之本：

- ``test_temperature_preserves_argmax``：校准不得改变模型选了哪个选项。
  改了就不是校准，而是用一个统计技巧掩盖模型判断。
- ``test_fit_improves_ece_on_overconfident_data``：校准必须在真正需要的场景下
  确实有效，而不只是数学上自洽。
"""

from __future__ import annotations

import numpy as np
import pytest

from vitalteen_ml import (
    CalibrationError,
    apply_temperature,
    comparison_table,
    correctness,
    evaluate,
    expected_calibration_error,
    fit_temperature,
    negative_log_likelihood,
    normalize,
    predicted_labels,
    top_confidence,
)

SEED = 20261003


def softmax(scores: np.ndarray) -> np.ndarray:
    shifted = scores - scores.max(axis=1, keepdims=True)
    weights = np.exp(shifted)
    return weights / weights.sum(axis=1, keepdims=True)


def make_overconfident_dataset(n: int = 3000, k: int = 3, sharpness: float = 4.0):
    """构造一个「既会犯错、又对自己的判断很自信」的模型输出。

    这正是 Laya 出厂状态的写照：第三方实测发现它答错时置信度可达 0.91。
    真实标签取自干净信号，模型看到的是加了噪声的信号并被过度锐化，
    因此它的错误率真实存在，而置信度却居高不下。
    """
    rng = np.random.default_rng(SEED)
    clean = rng.normal(0.0, 1.0, size=(n, k))
    labels = clean.argmax(axis=1)
    noisy = clean + rng.normal(0.0, 1.5, size=(n, k))
    return softmax(noisy * sharpness), labels


# --------------------------------------------------------------------------
# 归一化与基础量
# --------------------------------------------------------------------------


class TestNormalize:
    def test_rows_sum_to_one(self) -> None:
        out = normalize(np.array([[2.0, 2.0], [1.0, 3.0]]))
        assert np.allclose(out.sum(axis=1), 1.0)

    def test_all_zero_row_becomes_uniform_not_nan(self) -> None:
        """全零行没有可归一化的内容，退化为均匀分布 —— 产生 NaN 会污染整条链路。"""
        out = normalize(np.array([[0.0, 0.0, 0.0], [1.0, 1.0, 1.0]]))
        assert np.allclose(out[0], 1 / 3)
        assert np.all(np.isfinite(out))


class TestBasicQuantities:
    def test_top_confidence_is_the_maximum(self) -> None:
        assert np.allclose(top_confidence(np.array([[0.1, 0.7, 0.2]])), [0.7])

    def test_predicted_labels_pick_the_maximum(self) -> None:
        assert predicted_labels(np.array([[0.1, 0.7, 0.2]])).tolist() == [1]

    def test_ties_resolve_to_the_lower_index(self) -> None:
        """并列时取下标较小者 —— 确定且可复现，不依赖浮点比较的偶然性。"""
        assert predicted_labels(np.array([[0.5, 0.5]])).tolist() == [0]

    def test_correctness(self) -> None:
        probs = np.array([[0.9, 0.1], [0.2, 0.8]])
        assert correctness(probs, np.array([0, 0])).tolist() == [1.0, 0.0]


# --------------------------------------------------------------------------
# ECE
# --------------------------------------------------------------------------


class TestECE:
    def test_perfectly_calibrated_scores_zero(self) -> None:
        """置信度恰好等于准确率时 ECE 为 0。

        构造：全部样本置信度 0.5，其中一半答对 —— 桶内「准确率 0.5」与
        「平均置信度 0.5」完全吻合。
        """
        probs = np.array([[0.5, 0.5]] * 4)
        labels = np.array([0, 0, 1, 1])  # 两次答对、两次答错
        assert expected_calibration_error(probs, labels) == pytest.approx(0.0, abs=1e-12)

    def test_overconfidence_is_detected(self) -> None:
        """置信度 0.9 但只有一半答对 —— ECE 应当约为 0.4。

        这条正是 Laya 出厂状态的问题：平均置信度看起来很漂亮，
        但要按置信度分桶去看准确率，才能发现它对错误同样自信。
        """
        probs = np.array([[0.9, 0.1]] * 4)
        labels = np.array([0, 0, 1, 1])  # 一半答错
        assert expected_calibration_error(probs, labels) == pytest.approx(0.4, abs=1e-9)

    def test_underconfidence_is_also_detected(self) -> None:
        """ECE 取绝对值，因此「不够自信」与「过度自信」同样被记为偏差。"""
        # 置信度 0.5，但全部答对 → 偏差 0.5
        probs = np.array([[0.5, 0.5]] * 3)
        labels = np.array([0, 0, 0])
        assert expected_calibration_error(probs, labels) == pytest.approx(0.5, abs=1e-9)

    def test_single_bin_reduces_to_accuracy_minus_confidence(self) -> None:
        probs = np.array([[0.8, 0.2]] * 5)
        labels = np.array([0, 0, 0, 1, 1])
        ece = expected_calibration_error(probs, labels, n_bins=1)
        assert ece == pytest.approx(abs(0.6 - 0.8), abs=1e-9)

    def test_confidence_of_exactly_one_is_counted(self) -> None:
        """置信度恰好为 1.0 的样本必须落进最后一个桶，而不是被边界排除。

        分桶用左开右闭时，1.0 会掉出所有桶 —— 那会让最自信的那批样本
        （恰恰是最需要被审视的）完全逃过评测。
        """
        probs = np.array([[1.0, 0.0], [1.0, 0.0]])
        labels = np.array([0, 1])  # 一半答错，置信度却全是 1.0
        assert expected_calibration_error(probs, labels) == pytest.approx(0.5, abs=1e-9)

    def test_more_bins_finds_finer_structure(self) -> None:
        """分桶越细，越能看出结构；粗分桶会把偏差平均掉。"""
        rng = np.random.default_rng(SEED)
        probs = softmax(rng.normal(0, 2.0, size=(2000, 3)) * 3.0)
        labels = rng.integers(0, 3, size=2000)
        coarse = expected_calibration_error(probs, labels, n_bins=3)
        fine = expected_calibration_error(probs, labels, n_bins=15)
        assert fine > coarse

    @pytest.mark.parametrize("n_bins", [0, -1])
    def test_invalid_bin_count_is_rejected(self, n_bins: int) -> None:
        with pytest.raises(CalibrationError, match="n_bins"):
            expected_calibration_error(np.array([[0.5, 0.5]]), np.array([0]), n_bins=n_bins)


# --------------------------------------------------------------------------
# 温度缩放
# --------------------------------------------------------------------------


class TestTemperature:
    def test_identity_at_one(self) -> None:
        probs = np.array([[0.2, 0.8]])
        assert np.allclose(apply_temperature(probs, 1.0), probs)

    def test_preserves_argmax(self) -> None:
        """**这是整套东西的立身之本。**

        校准若改变了模型选了哪个选项，那就不是校准 —— 权重一个都没动，
        变的只是我们敢不敢拿那个置信度去做门控。用统计技巧改答案，
        等于用一个我们无法解释的手段覆盖模型的判断。
        """
        rng = np.random.default_rng(SEED)
        probs = softmax(rng.normal(0, 1.0, size=(500, 4)))
        original = predicted_labels(probs)
        for temperature in (0.1, 0.5, 1.0, 2.0, 10.0):
            assert np.array_equal(
                predicted_labels(apply_temperature(probs, temperature)), original
            ), f"T={temperature} 改变了选择结果"

    def test_above_one_softens(self) -> None:
        probs = np.array([[0.9, 0.1]])
        softened = apply_temperature(probs, 3.0)
        assert softened[0, 0] < probs[0, 0]
        assert np.allclose(softened.sum(axis=1), 1.0)

    def test_below_one_sharpens(self) -> None:
        probs = np.array([[0.6, 0.4]])
        sharpened = apply_temperature(probs, 0.5)
        assert sharpened[0, 0] > probs[0, 0]

    def test_output_is_a_distribution(self) -> None:
        rng = np.random.default_rng(SEED)
        probs = softmax(rng.normal(0, 2.0, size=(100, 5)))
        out = apply_temperature(probs, 2.5)
        assert np.allclose(out.sum(axis=1), 1.0)
        assert np.all(out >= 0)

    @pytest.mark.parametrize("temperature", [0.0, -1.0, float("inf"), float("nan")])
    def test_invalid_temperature_is_rejected(self, temperature: float) -> None:
        with pytest.raises(CalibrationError, match="temperature"):
            apply_temperature(np.array([[0.5, 0.5]]), temperature)


class TestNegativeLogLikelihood:
    def test_confident_and_correct_is_cheap(self) -> None:
        assert negative_log_likelihood(np.array([[0.99, 0.01]]), np.array([0])) < 0.02

    def test_confident_and_wrong_is_expensive(self) -> None:
        assert negative_log_likelihood(np.array([[0.99, 0.01]]), np.array([1])) > 4.0


# --------------------------------------------------------------------------
# 温度拟合
# --------------------------------------------------------------------------


class TestFitTemperature:
    def test_fit_improves_ece_on_overconfident_data(self) -> None:
        """**校准必须在真正需要的场景下确实有效**，而不只是数学上自洽。

        数据集刻意构造成「既犯错又自信」—— 正是 Laya 出厂状态的样子。
        """
        probs, labels = make_overconfident_dataset()
        before = expected_calibration_error(probs, labels)

        fit = fit_temperature(probs, labels)
        after = expected_calibration_error(apply_temperature(probs, fit.temperature), labels)

        assert fit.temperature > 1.0, "过度自信的数据应当拟合出大于 1 的温度"
        assert after < before / 3, f"ECE 下降不足：{before:.4f} → {after:.4f}"

    def test_fit_preserves_accuracy(self) -> None:
        """校准改变了置信度，但**不得改变任何一个样本的答案**。

        因此准确率必须逐位不变。若这条失败，说明温度缩放实现里混进了
        非线性操作（例如对概率做了除法以外的变换）。
        """
        probs, labels = make_overconfident_dataset()
        before = correctness(probs, labels).mean()
        fit = fit_temperature(probs, labels)
        after = correctness(apply_temperature(probs, fit.temperature), labels).mean()
        assert after == before

    def test_fit_never_makes_nll_worse(self) -> None:
        """拟合不出改善时返回恒等变换，而不是一个更差的温度。"""
        probs, labels = make_overconfident_dataset()
        fit = fit_temperature(probs, labels)
        assert fit.nll_after <= fit.nll_before + 1e-12
        assert fit.improvement >= -1e-12

    def test_well_calibrated_data_yields_neutral_temperature(self) -> None:
        """本来就校准好的数据不该被强行改造。

        **构造方式很关键，不能靠调锐化系数凑。** 起初我把 ``sharpness=1.0``
        当作「校准良好」，实测下来它仍然偏过度自信（NLL 从 1.018 降到 0.906，
        说明软化是对的），于是那条断言测的其实是我的错误直觉。

        正确做法是**让标签从模型自己的概率里采样**：这样它在期望意义下就是
        校准的，拟合出的温度才应当接近 1。
        """
        rng = np.random.default_rng(SEED)
        n, k = 6000, 3
        probs = softmax(rng.normal(0.0, 1.5, size=(n, k)))
        labels = np.array([rng.choice(k, p=row) for row in probs])

        fit = fit_temperature(probs, labels)
        assert 0.6 < fit.temperature < 1.6, fit.temperature

        # 更本质的一条：不该把本来就不错的 ECE 弄坏
        before = expected_calibration_error(probs, labels)
        after = expected_calibration_error(apply_temperature(probs, fit.temperature), labels)
        assert after <= before + 0.02, f"{before:.4f} → {after:.4f}"

    def test_fit_is_deterministic(self) -> None:
        probs, labels = make_overconfident_dataset(n=500)
        assert fit_temperature(probs, labels).temperature == pytest.approx(
            fit_temperature(probs, labels).temperature
        )

    def test_fit_converges(self) -> None:
        probs, labels = make_overconfident_dataset(n=500)
        assert fit_temperature(probs, labels).converged is True

    def test_extreme_sharpness_is_handled(self) -> None:
        """极端锐化的输出（置信度接近 1）不应让搜索发散或产出非法温度。"""
        probs, labels = make_overconfident_dataset(n=800, sharpness=20.0)
        fit = fit_temperature(probs, labels)
        assert np.isfinite(fit.temperature)
        assert fit.temperature > 0


# --------------------------------------------------------------------------
# 评测与对比表
# --------------------------------------------------------------------------


class TestEvaluation:
    def test_fields_are_consistent(self) -> None:
        probs, labels = make_overconfident_dataset(n=1000)
        result = evaluate(probs, labels, label="baseline")
        assert result.label == "baseline"
        assert result.n == 1000
        assert 0.0 <= result.accuracy <= 1.0
        assert 0.0 <= result.ece <= 1.0
        assert result.mean_confidence > result.accuracy, "该数据集刻意构造成过度自信"

    def test_n_bins_is_forwarded(self) -> None:
        probs, labels = make_overconfident_dataset(n=800)
        coarse = evaluate(probs, labels, n_bins=2)
        fine = evaluate(probs, labels, n_bins=20)
        assert fine.ece != coarse.ece


class TestComparisonTable:
    def test_renders_all_configurations(self) -> None:
        """计划书要求的「基线 / 微调 / 微调+校准」三栏对比就是它。"""
        probs, labels = make_overconfident_dataset(n=800)
        baseline = evaluate(probs, labels, label="基线")
        fit = fit_temperature(probs, labels)
        calibrated = evaluate(
            apply_temperature(probs, fit.temperature), labels, label="微调+校准"
        )
        table = comparison_table([baseline, calibrated])
        assert "基线" in table
        assert "微调+校准" in table
        assert len(table.splitlines()) == 4  # 表头 + 分隔 + 两行数据

    def test_empty_input(self) -> None:
        assert comparison_table([]) == "（无评测结果）"


class TestInputValidation:
    @pytest.mark.parametrize(
        ("probs", "labels", "message"),
        [
            (np.array([0.5, 0.5]), np.array([0]), "二维"),
            (np.array([[0.5, 0.5]]), np.array([0, 1]), "长度"),
            (np.array([[0.5, 0.5]]), np.array([2]), "越界"),
            # 形状必须是 (0, k) 才是真正「零样本」；np.array([[]]) 的形状是 (1, 0)，
            # 样本数为 1，先触发的是标签长度检查。
            (np.zeros((0, 2)), np.array([], dtype=int), "样本数为 0"),
            (np.array([[0.5]]), np.array([0]), "至少需要 2 个类别"),
            (np.array([[0.5, float("nan")]]), np.array([0]), "非有限值"),
            (np.array([[0.5, -0.2]]), np.array([0]), "不能为负"),
        ],
    )
    def test_invalid_inputs_are_rejected(
        self, probs: np.ndarray, labels: np.ndarray, message: str
    ) -> None:
        with pytest.raises(CalibrationError, match=message):
            expected_calibration_error(probs, labels)
