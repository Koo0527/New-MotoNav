#!/usr/bin/env python3
# 175c.12diag HeapChecks 宿主测试：
# 1) 编译并运行 main.cpp（ASan/UBSan）：正常轮转 / 空闲强制遍历 / 损坏即停 / 环形记录 / 10s 自证行。
# 2) 校验固件源里的打点布线（阶段齐全、范围封闭——正式版移除 = grep HEAPCHK 零残留）。
import pathlib, subprocess, tempfile
root = pathlib.Path(__file__).resolve().parents[3]
src = root / 'firmware/boards/175/MotoNav'

with tempfile.TemporaryDirectory() as d:
    out = pathlib.Path(d)
    subprocess.run(['c++', '-std=c++17', '-fsanitize=address,undefined',
                    f'-I{pathlib.Path(__file__).parent}/stub',
                    f'-I{src}/src',
                    pathlib.Path(__file__).with_name('main.cpp'),
                    '-o', out / 'heapchecks'], check=True)
    subprocess.run([out / 'heapchecks'], check=True)

# 布线断言（正式版 175c.13 起）：诊断打点零残留（HeapChecks.h 仅作为独立工具留在树中，固件源不引用）
ino = (src / 'MotoNav.ino').read_text()
assert 'HeapChecks.h' not in ino and 'HEAPCHK(' not in ino, 'diagnostic leftovers in MotoNav.ino'
for path in src.rglob('*.h'):
    if path.name == 'HeapChecks.h':
        continue  # 工具本体，允许包含 HEAPCHK 宏定义
    assert 'HEAPCHK(' not in path.read_text(), f'diagnostic leftovers in {path}'

# 根因修复布线：Wire.begin 后必须扩容 rxBuffer，否则 SensorLib FIFO 240B 单块读溢出 128B 默认缓冲
import re
m = re.search(r'Wire\.begin\([^)]*\);\s*\n(.*?)Wire\.setBufferSize\((\d+)\)', ino, re.S)
assert m and int(m.group(2)) >= 256, 'Wire.setBufferSize(>=256) must follow Wire.begin'
print('heap-checks wiring + host regression passed')
