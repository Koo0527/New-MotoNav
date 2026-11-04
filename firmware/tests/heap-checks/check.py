#!/usr/bin/env python3
# 175c.12diag HeapChecks 宿主测试 + 175c.15 Wire 启动失败路径行为测试：
# 1) 编译并运行 main.cpp（ASan/UBSan）：正常轮转 / 空闲强制遍历 / 损坏即停 / 环形记录 /
#    10s 自证行（含 175c.14 stMinB 字节单位回归断言）。
# 2) 校验固件源里的打点布线（正式版移除 = grep HEAPCHK 零残留）。
# 3) 从生产 MotoNav.ino 提取 setup() 入口至首个 pinMode(0,INPUT_PULLUP) 行（含）的
#    真实代码，与 wire-startup.cpp（Fake Wire 按 SDK 语义桩化）编译运行 6 场景；
#    175c.15 起以此行为测试替代恢复链文本正则——注释/if(0)/裸调用等绕过形态
#    由行为断言天然拒绝，另对 5 种负向变体（临时副本上篡改）逐一验证必败。
import pathlib, re, subprocess, tempfile
root = pathlib.Path(__file__).resolve().parents[3]
src = root / 'firmware/boards/175/MotoNav'
here = pathlib.Path(__file__).parent

with tempfile.TemporaryDirectory() as d:
    out = pathlib.Path(d)
    subprocess.run(['c++', '-std=c++17', '-fsanitize=address,undefined',
                    f'-I{here}/stub',
                    f'-I{src}/src',
                    here / 'main.cpp',
                    '-o', out / 'heapchecks'], check=True)
    subprocess.run([out / 'heapchecks'], check=True)

# 布线断言（正式版 175c.13 起）：诊断打点零残留（HeapChecks.h 仅作为独立工具留在树中，固件源不引用）
ino_path = src / 'MotoNav.ino'
ino = ino_path.read_text()
assert 'HeapChecks.h' not in ino and 'HEAPCHK(' not in ino, 'diagnostic leftovers in MotoNav.ino'
for path in src.rglob('*.h'):
    if path.name == 'HeapChecks.h':
        continue  # 工具本体，允许包含 HEAPCHK 宏定义
    assert 'HEAPCHK(' not in path.read_text(), f'diagnostic leftovers in {path}'

# ===== Wire 启动失败路径行为测试（175c.15）=====
def extract_setup_head(ino_text: str) -> str:
    """提取 setup() 入口至首个 pinMode(0,INPUT_PULLUP) 行（含）的真实生产代码，
    并补上闭合 '}' 使其成为完整函数（提取即所得，不改写语句）。"""
    start = ino_text.index('void setup() {')
    pin = ino_text.index('pinMode(0,INPUT_PULLUP);', start)
    end = ino_text.index('\n', pin) + 1
    return ino_text[start:end] + '}\n'

def build_and_run(ino_text: str, workdir: pathlib.Path, tag: str):
    """提取+编译+运行；返回 (编译成功, 运行退出码, 错误输出)。"""
    exe = workdir / f'wire-startup-{tag}'
    (workdir / f'setup_head-{tag}.inc').write_text(extract_setup_head(ino_text))
    comp = subprocess.run(['c++', '-std=c++17', '-fsanitize=address,undefined',
                           f'-DSETUP_INC="setup_head-{tag}.inc"',
                           '-I', str(workdir),
                           here / 'wire-startup.cpp', '-o', str(exe)],
                          capture_output=True, text=True)
    if comp.returncode != 0:
        return False, None, comp.stderr
    run = subprocess.run([exe], capture_output=True, text=True)
    return True, run.returncode, run.stderr

with tempfile.TemporaryDirectory() as d:
    work = pathlib.Path(d)
    ok, rc, err = build_and_run(ino, work, 'real')
    assert ok, f'wire-startup compile failed against production setup()\n{err}'
    assert rc == 0, f'wire-startup scenarios FAILED (rc={rc}) against production setup()\n{err}'

    # 负向变体：在临时副本上篡改。门槛=必须能编译（手术不得引入语法错误），且以
    # 场景断言失败的方式被拒绝——stderr 含 'FAIL ' 行（EXPECT 宏输出）。编译错误、
    # Sanitizer 故障或异常终止都不能冒充预期的负向测试结果。
    # 区间锚点 = 'if (Wire.setBufferSize(512)' 起至 'pinMode(0,INPUT_PULLUP);' 前；
    # 找不到锚点即变体失效，视为失败。
    def resize_region(t):
        a = t.index('if (Wire.setBufferSize(512)')
        b = t.index('pinMode(0,INPUT_PULLUP);', a)
        return a, b

    variants = {
        'block-comment': lambda t: (lambda ab: t[:ab[0]] + '/* Wire resize disabled */\n' + t[ab[1]:])(resize_region(t)),
        'if0-wrap': lambda t: (lambda ab: t[:ab[0]] + 'if (0) {\n' + t[ab[0]:ab[1]] + '}\n' + t[ab[1]:])(resize_region(t)),
        'bare-call': lambda t: (lambda ab: t[:ab[0]] + 'Wire.setBufferSize(512);\n' + t[ab[1]:])(resize_region(t)),
        'no-realloc': lambda t: (lambda ab: t[:ab[0]] + 'if (Wire.setBufferSize(512) != 512) allocFailHalt("Wire", 512);\n' + t[ab[1]:])(resize_region(t)),
        'ignore-end-failure': lambda t: t.replace('!Wire.end() ||', 'Wire.end(),', 1),
    }
    for name, mutate in variants.items():
        mutated = mutate(ino)
        assert mutated != ino, f'variant {name}: anchor not found (mutation no-op)'
        ok, rc, err = build_and_run(mutated, work, name)
        assert ok, f'{name}: mutation must compile\n{err}'
        assert rc != 0, f'{name}: mutation unexpectedly passed'
        assert any(line.startswith('FAIL ') for line in err.splitlines()), \
            f'{name}: expected scenario assertion failure\n{err}'

    # 手术自检：制造语法错误的副本必须让 runner 整体失败（编译失败不可计为有效负向测试）
    a, b = resize_region(ino)
    broken = ino[:a] + 'if (Wire.setBufferSize(512) syntax-error {\n' + ino[b:]
    ok, rc, err = build_and_run(broken, work, 'syntax-broken')
    assert not ok, 'syntax-broken control: expected compile failure'

print('heap-checks wiring + host regression + wire-startup behavior passed')
