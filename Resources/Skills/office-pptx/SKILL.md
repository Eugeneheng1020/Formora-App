---
name: office-pptx
description: 用户提到 PPT、幻灯片、演示、deck 或 .pptx 时用：读取或生成 .pptx——提取每页文字、按模板成套出片。用 python-pptx，装在项目文件夹里跑。
---

# PPT 演示（pptx）

## 先做这两件事（Formora 特有）

### 1. 找到一个真能用的 python3

沙盒里 `/usr/bin/python3` 是垫片，会报 `cannot be used within an App Sandbox`：

```bash
for p in /opt/homebrew/bin/python3 /usr/local/bin/python3 \
         /Library/Frameworks/Python.framework/Versions/Current/bin/python3; do
  [ -x "$p" ] && "$p" -c "print('ok')" >/dev/null 2>&1 && echo "PY=$p" && break
done
```

一个都没有就直接告诉用户去装 Python。

### 2. 依赖装进项目文件夹

```bash
"$PY" -m pip install --target .formora-py python-pptx
```

## 读

```python
import sys; sys.path.insert(0, ".formora-py")
from pptx import Presentation
prs = Presentation("方案.pptx")
for i, slide in enumerate(prs.slides, 1):
    print(f"=== 第 {i} 页（版式：{slide.slide_layout.name}）===")
    for shape in slide.shapes:
        if shape.has_text_frame and shape.text_frame.text.strip():
            print(shape.text_frame.text)
        if shape.has_table:
            for row in shape.table.rows:
                print(" | ".join(c.text for c in row.cells))
```

## 生成

**优先用模板**：`Presentation("模板.pptx")` 会带上母版、配色和版式，比空白文档手搓
排版靠谱得多。先 `glob` 看看项目里有没有 `.pptx` 模板。

```python
import sys; sys.path.insert(0, ".formora-py")
from pptx import Presentation
from pptx.util import Inches, Pt
prs = Presentation()                      # 有模板就传模板路径
title_layout, bullet_layout = prs.slide_layouts[0], prs.slide_layouts[1]

s = prs.slides.add_slide(title_layout)
s.shapes.title.text = "会员体系方案"
s.placeholders[1].text = "2026 Q1"

s = prs.slides.add_slide(bullet_layout)
s.shapes.title.text = "三条核心需求"
tf = s.placeholders[1].text_frame
tf.text = "付费会员身份"
for line in ["成长值等级", "权益引擎"]:
    p = tf.add_paragraph(); p.text = line; p.level = 0

prs.save("方案/会员体系_v1.pptx")
```

**一页只讲一件事**：标题是结论，正文三到五条。把一整页文档倒进一页 PPT 是最常见
的失败。有数字就放表格（`s.shapes.add_table`），别写成一段话。

## 纪律

- **写完读回来验证**：跑一次读取脚本，确认每一页的文字都在。
- **你看不到版式。** Formora 没法把幻灯片渲染成图片检查，文字只能读回来核对。交付时
  告诉用户在 Keynote 或 PowerPoint 里打开看一眼，尤其是字多的那几页。
- **不要用 `read` 工具打开 .pptx**，是 zip。
- 文本框会溢出且不会自动缩字号——每页文字控制在五条以内，长句拆短。
