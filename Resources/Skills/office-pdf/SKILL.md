---
name: office-pdf
description: 只要涉及 PDF 就用：读正文、取表格、拆分合并、填可填写的表单、生成简单的 PDF。用 pypdf / pdfplumber / reportlab，装在项目文件夹里跑。
---

# PDF 文档

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
"$PY" -m pip install --target .formora-py pypdf
```

读正文、拆分合并、填表单装 `pypdf` 就够；要取表格再加 `pdfplumber`（体积大不少），
要生成 PDF 再加 `reportlab`。

## 读正文

```python
import sys; sys.path.insert(0, ".formora-py")
from pypdf import PdfReader
r = PdfReader("合同.pdf")
print(f"共 {len(r.pages)} 页")
for i, page in enumerate(r.pages[:10], 1):        # 先看前十页，别一次全倒进上下文
    text = (page.extract_text() or "").strip()
    print(f"--- 第 {i} 页 ---\n{text}")
```

**取不到文字**说明它是扫描件（页面是图）。这时候不要硬猜内容——告诉用户这是扫描
版，需要 OCR；或者用 Formora 的看图能力：把那几页导成图片给会看图的模型读。

## 取表格

```python
import sys; sys.path.insert(0, ".formora-py")
import pdfplumber
with pdfplumber.open("报表.pdf") as pdf:
    for i, page in enumerate(pdf.pages, 1):
        for t in page.extract_tables():
            print(f"--- 第 {i} 页的表 ---")
            for row in t:
                print(" | ".join((c or "").strip() for c in row))
```

## 拆分与合并

```python
import sys; sys.path.insert(0, ".formora-py")
from pypdf import PdfReader, PdfWriter
r = PdfReader("全本.pdf"); w = PdfWriter()
for p in r.pages[2:8]:      # 第 3–8 页
    w.add_page(p)
with open("节选.pdf", "wb") as f:
    w.write(f)
```

## 填表单

```python
import sys; sys.path.insert(0, ".formora-py")
from pypdf import PdfReader, PdfWriter
r = PdfReader("申请表.pdf")
print(r.get_fields())        # None 说明它不是可填写的表单，只是长得像表格
w = PdfWriter(); w.append(r)
w.update_page_form_field_values(w.pages[0], {"姓名": "张三", "日期": "2026-09-11"})
w.write("申请表_已填.pdf")
```

字段名以 `get_fields()` 打出来的为准，不要按页面上看到的字猜。

## 生成简单的 PDF

```python
import sys; sys.path.insert(0, ".formora-py")
from reportlab.lib.pagesizes import A4
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.cidfonts import UnicodeCIDFont
from reportlab.pdfgen import canvas
pdfmetrics.registerFont(UnicodeCIDFont("STSong-Light"))   # reportlab 自带的中文字体
c = canvas.Canvas("周报.pdf", pagesize=A4)
c.setFont("STSong-Light", 12)
c.drawString(72, 770, "本周挽回率 8.2%，比上周高 0.6 个点。")
c.save()
```

封面、目录、页眉页脚这类复杂排版，先按 Word 技能做成 .docx，再请用户在 Word 或
Pages 里导出 PDF，比手算坐标可靠。

## 纪律

- **不要用 `read` 工具打开 PDF**，二进制，读出来是乱码。
- **长文档分页读**，一次读几百页会把上下文吃光；先看目录页定位再精读。
- **生成、填写之后读回来验证**：用 `pypdf` 把文字和字段读回来，确认中文不是空白或方块。
- **扫描件就说是扫描件**，不要根据文件名编造里面的内容。
