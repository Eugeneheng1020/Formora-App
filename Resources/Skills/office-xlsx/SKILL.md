---
name: office-xlsx
description: 表格文件是输入或产出时用（.xlsx、.csv，用户说「这张表」「做个 Excel」）：取数、清洗、写回带公式和格式的表。用 openpyxl，装在项目文件夹里跑。
---

# Excel 表格（xlsx）

## 先做这两件事（Formora 特有）

### 1. 找到一个真能用的 python3

沙盒里 `/usr/bin/python3` 是垫片，会报 `cannot be used within an App Sandbox`：

```bash
for p in /opt/homebrew/bin/python3 /usr/local/bin/python3 \
         /Library/Frameworks/Python.framework/Versions/Current/bin/python3; do
  [ -x "$p" ] && "$p" -c "print('ok')" >/dev/null 2>&1 && echo "PY=$p" && break
done
```

一个都没有就直接告诉用户去装 Python，别绕过去。

### 2. 依赖装进项目文件夹

```bash
"$PY" -m pip install --target .formora-py openpyxl
```

只处理 CSV 的话不用装：Python 自带的 `csv` 模块就能读写。带中文的 CSV 用
`encoding="utf-8-sig"` 写，Excel 打开才不乱码。

## 读

```python
import sys; sys.path.insert(0, ".formora-py")
from openpyxl import load_workbook
wb = load_workbook("报表.xlsx", data_only=True)   # data_only=True 拿公式的结果值
ws = wb["Sheet1"]                                  # 或 wb.active
print(ws.max_row, ws.max_column)
for row in ws.iter_rows(min_row=1, max_row=20, values_only=True):
    print(row)
```

- **`data_only=True` 读到的是上次 Excel 算好的值**；文件从没被 Excel 打开过时是
  `None`。这时要读公式本身就用 `data_only=False`。
- 大表先只读前几十行摸清表头，不要一次全打印进上下文。

## 写

```python
import sys; sys.path.insert(0, ".formora-py")
from openpyxl import Workbook
from openpyxl.styles import Font
wb = Workbook(); ws = wb.active; ws.title = "汇总"
ws.append(["月份", "订单数", "客单价", "GMV"])
for c in ws[1]: c.font = Font(bold=True)
ws.append(["1月", 1200, 88.5, "=B2*C2"])          # 公式直接写字符串
ws.column_dimensions["A"].width = 12
wb.save("数据/汇总_v1.xlsx")
```

**openpyxl 只写公式、不算公式**：文件要在 Excel 里打开一次才有结果。所以交付前自己
核对——引用的单元格对不对、范围有没有差一行，能用 Python 先把几行结果算出来对一下
就对一下；交出去的表里不能有 `#REF!`、`#DIV/0!` 这类错误。交付时告诉用户公式的
结果打开后才会显示。

改现有文件用 `load_workbook("x.xlsx")` 再 `save()`——**注意 openpyxl 会丢掉它不认识
的东西（图表、部分格式）**，改别人的重要表格前先复制一份备份。改的时候照着原表的
格式、字体和写法来，不要换成你自己的风格。

## 纪律

- **写完读回来验证**：`load_workbook(..., data_only=False)` 确认单元格和公式都在。
- **不要用 `read` 工具打开 .xlsx**，是 zip，读出来是乱码。
- 数字别写成字符串——写成字符串的数在 Excel 里不能求和，用户会以为你算错了。
