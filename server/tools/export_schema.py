"""导出决策契约的 JSON Schema。

用法::

    python -m tools.export_schema            # 重新生成
    python -m tools.export_schema --check    # 只校验是否同步（CI 与本地自检）

**为什么需要这个**

契约是三方（手机端 Dart / 决策服务 Python / 大屏与报告）的共同边界，
而它的权威定义在 ``server/app/contracts.py`` 里 —— 那是一份 Python 代码。
端侧团队不该靠读 Python 来猜字段名与可空性，那是必然出错的传递方式。

导出成 JSON Schema 之后，端侧可以：

- 用代码生成器（``json_serializable`` / ``quicktype`` 等）生成 Dart 模型类
- 在 CI 里做本地校验，字段拼错时**在端侧就报错**，而不是等发到服务端才 400

**与 golden fixtures 是同一套思路。** 那份锁定「特征算得对不对」，
这份锁定「请求与响应的结构对不对」。两者都必须在实现改动时同步更新，
因此都提供 ``--check`` 模式：不同步就失败，逼迫改动者显式确认这是有意的变更。
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from app.contracts import DecisionRequest, DecisionResponse

REPO_ROOT = Path(__file__).resolve().parents[2]
OUT_DIR = REPO_ROOT / "shared" / "contracts"

#: 导出哪些模型。文件名即端侧引用时的标识。
SCHEMAS: dict[str, Any] = {
    "decision_request.schema.json": DecisionRequest,
    "decision_response.schema.json": DecisionResponse,
}


def build() -> dict[str, str]:
    """生成全部 schema 文本，键为文件名。"""
    out: dict[str, str] = {}
    for filename, model in SCHEMAS.items():
        schema = model.model_json_schema()
        # 补上出处与用法，让端侧拿到文件时不必去翻仓库
        schema["$comment"] = (
            f"由 server/tools/export_schema.py 从 app/contracts.py 的 {model.__name__} 导出。"
            "请勿手工编辑本文件 —— 修改契约请改 Python 定义后重新导出。"
        )
        out[filename] = json.dumps(schema, ensure_ascii=False, indent=2, sort_keys=False) + "\n"
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description="导出决策契约 JSON Schema")
    parser.add_argument(
        "--check", action="store_true", help="仅校验现有文件是否与契约同步，不写入"
    )
    args = parser.parse_args()

    generated = build()

    if args.check:
        stale = [
            name
            for name, text in generated.items()
            if not (OUT_DIR / name).exists() or (OUT_DIR / name).read_text(encoding="utf-8") != text
        ]
        if stale:
            print(
                f"以下 schema 与契约不同步：{sorted(stale)}\n"
                "若这是有意的契约变更，请运行 `python -m tools.export_schema` 重新导出，"
                "并在提交信息里说明变化原因（端侧需要同步跟进）；"
                "若是意外漂移，说明有人改了契约定义却没走导出流程。",
                file=sys.stderr,
            )
            return 1
        print(f"schema 与契约同步：{OUT_DIR}")
        return 0

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for name, text in generated.items():
        (OUT_DIR / name).write_text(text, encoding="utf-8")
    print(f"已写入 {len(generated)} 个 schema 到 {OUT_DIR}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
