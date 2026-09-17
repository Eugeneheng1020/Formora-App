---
name: office-docx
description: 用户提到 Word、.docx，或要一份 Word 版的报告、合同、说明时用：读取或生成 .docx——提取正文与表格、按模板填内容、把 Markdown 交付成 Word。用 python-docx，装在项目文件夹里跑。
---

# Word 文档（docx）

## 先做这两件事（Formora 特有）

### 1. 找到一个真能用的 python3

Formora 跑在 App 沙盒里，**系统自带的 `/usr/bin/python3` 是一个转发垫片，在沙盒里
会直接报 `cannot be used within an App Sandbox`**。要找一个真实安装的解释器：

```bash
for p in /opt/homebrew/bin/python3 /usr/local/bin/python3 \
         /Library/Frameworks/Python.framework/Versions/Current/bin/python3; do
  [ -x "$p" ] && "$p" -c "print('ok')" >/dev/null 2>&1 && echo "PY=$p" && break
done
```

一个都没有，就**直接告诉用户**：这台机器上没有可用的 Python，去
python.org 或 `brew install python` 装一个，装完这个技能才能用。**不要绕过去假装
做完了。**

### 2. 依赖装进项目文件夹

沙盒里只有项目文件夹可写，所以不要装到系统 site-packages：

```bash
"$PY" -m pip install --target .formora-py python-docx
```

之后每次运行都带上 `PYTHONPATH=.formora-py`。把 `.formora-py` 加进 `.gitignore`。

## 读一份 .docx

```python
import sys; sys.path.insert(0, ".formora-py")
from docx import Document
d = Document("需求.docx")
for p in d.paragraphs:
    if p.text.strip():
        print(f"[{p.style.name}] {p.text}")
for i, t in enumerate(d.tables):
    print(f"--- 表 {i+1} ---")
    for row in t.rows:
        print(" | ".join(c.text.strip() for c in row.cells))
```

标题层级在 `p.style.name`（`Heading 1`…），提取结构时按它分段。

## 生成一份 .docx

```python
import sys; sys.path.insert(0, ".formora-py")
from docx import Document
from docx.shared import Mm
d = Document()                      # 有模板就 Document("模板.docx")，样式会跟着走
s = d.sections[0]                   # 空白文档默认是美国 Letter 纸，国内用 A4
s.page_width, s.page_height = Mm(210), Mm(297)
d.add_heading("会员体系需求", level=1)
d.add_paragraph("这一版要解决的问题是……")
t = d.add_table(rows=1, cols=3); t.style = "Table Grid"
for i, h in enumerate(["需求", "复杂度", "负责人"]):
    t.rows[0].cells[i].text = h
d.save("PRD/会员体系_v1.docx")
```

**有模板就用模板**：`Document("模板.docx")` 会继承它的纸张、样式、页眉页脚和字体，
比从空文档手搓格式可靠得多。先 `glob` 找找项目里有没有现成模板。标题用
`add_heading`，别用加粗的普通段落冒充——Word 的导航和目录只认标题样式。

## 纪律

- **写完必须读回来验证**：再跑一次读取脚本，确认段落和表格真的在里面。
- **不要把 .docx 当文本文件 `read`**，它是 zip，读出来是乱码。
- **python-docx 做不了修订痕迹和批注。** 用户要「带修订」的版本，直接说做不到，
  给一份改好的新版本，并列出改了哪些地方。
- 中文字体在别人机器上可能缺；正文别指定具体字体，跟模板走。
