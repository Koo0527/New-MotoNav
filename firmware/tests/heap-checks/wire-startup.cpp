// 175c.15 Wire 启动失败路径行为测试：被测对象是从生产 MotoNav.ino 提取的真实
// setup() 头段（check.py 运行时生成 setup_head.inc，入口至首个 pinMode 行含），
// 本文件只提供平台桩——不复写任何初始化算法。
// Fake TwoWire 忠实模拟本 SDK（Arduino 3.3.10 Wire.cpp）语义：
//   - setBufferSize(n) 失败：freeWireBuffer() 已执行、指针置 NULL、bufferSize 已改成 n、返回 0
//   - setBufferSize(n) 双缓冲为 NULL：只登记 bufferSize=n 直接返回 n，【不分配】
//   - begin()：总线已初始化 → 返回 true 且【不分配】；未初始化 → 分配 rx/tx 并置 busInit
//   - end()：成功 → 注销总线并释放缓冲；注入失败 → 返回 false 且保留原状态
// allocFailHalt 以异常截获（真实版打印堆况后重启，见 DeviceContext.h）。
#include <algorithm>
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdexcept>
#include <string>
#include <vector>

// ===== 平台/生产桩（仅桩化，不实现逻辑）=====
static void makeBleName() {}
struct SerialCapture {
  void begin(unsigned long) {}
  void setTxTimeoutMs(unsigned long) {}
  void println(const char* s) { lines.push_back(s); }
  void printf(const char*, ...) { lines.push_back("<printf>"); }
  std::vector<std::string> lines;
};
static SerialCapture Serial;
static int esp_reset_reason() { return 0; }
static int esp_sleep_get_wakeup_cause() { return 0; }
static constexpr int IIC_SDA = 8, IIC_SCL = 9;

struct HaltException : std::runtime_error {
  HaltException(const char* name) : std::runtime_error(name) {}
};
static void allocFailHalt(const char* name, size_t) { throw HaltException(name); }

static std::vector<int> pinModeCalls;
static constexpr int INPUT_PULLUP = 0x02;
static void pinMode(int pin, int) { pinModeCalls.push_back(pin); }

// ===== Fake Wire（SDK 语义，见文件头注释）=====
struct FakeWire {
  uint8_t* rx = nullptr;
  uint8_t* tx = nullptr;
  size_t bufferSize = 0;
  bool busInit = false;
  bool everBegan = false;   // 注入区分“首次 begin”与“end 后重建 begin”
  // 注入开关
  bool failFirstBegin = false;
  bool failSet512 = false;
  bool failEnd = false;
  bool failSet256 = false;
  bool failBeginAfterEnd = false;
  std::vector<std::string> calls;

  void freeWireBuffer() {
    delete[] rx; rx = nullptr;
    delete[] tx; tx = nullptr;
  }
  bool allocOk(size_t n) {
    if (n == 512 && failSet512) return false;
    if (n == 256 && failSet256) return false;
    return true;
  }
  size_t setBufferSize(size_t n) {
    calls.push_back("setBufferSize(" + std::to_string(n) + ")");
    if (!allocOk(n)) {                             // 注入失败：SDK 失败语义（先释放、改尺寸、返回 0）；
      freeWireBuffer();                             // 双 NULL 分支现 SDK 不失败，此处为防御性守卫注入
      bufferSize = n;
      return 0;
    }
    if (rx != nullptr || tx != nullptr) {          // Wire.cpp:198 分支
      if (n != bufferSize) {
        freeWireBuffer();                           // 先释放旧缓冲
        bufferSize = n;
        rx = new uint8_t[n]; tx = new uint8_t[n];
      }
      return n;
    }
    bufferSize = n;                                // Wire.cpp:210 双 NULL：只登记不分配
    return n;
  }
  bool begin(int, int) {
    calls.push_back("begin");
    if (busInit) return true;                      // Wire.cpp:299 已初始化：不分配
    bool injected = everBegan ? failBeginAfterEnd : failFirstBegin;
    if (injected) return false;
    rx = new uint8_t[bufferSize]; tx = new uint8_t[bufferSize];
    busInit = true; everBegan = true;
    return true;
  }
  bool end() {
    calls.push_back("end");
    if (failEnd) return false;                     // 注销失败：保留原状态
    busInit = false;
    freeWireBuffer();
    return true;
  }
  bool usable(size_t n) const { return rx && tx && bufferSize == n; }
  bool called(const std::string& s) const {
    for (auto& c : calls) if (c == s) return true;
    return false;
  }
};
static FakeWire Wire;

#ifndef SETUP_INC
#error "wire-startup.cpp must be built by check.py, which extracts the production setup() head"
#endif
#include SETUP_INC   // 生产代码：setup() 入口至首个 pinMode(0,INPUT_PULLUP) 行（check.py 提取生成）

// ===== 场景驱动 =====
struct Result {
  bool halted = false;
  std::string haltName;
};
static Result run(FakeWire w) {
  Wire = w; Serial.lines.clear(); pinModeCalls.clear();
  Result r;
  try { setup(); } catch (const HaltException& e) { r.halted = true; r.haltName = e.what(); }
  return r;
}
#define EXPECT(cond) do { if (!(cond)) { std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); std::exit(1); } } while (0)

int main() {
  { // S1 首次 begin() 失败 → halt("Wire.begin")；不得继续扩容，不得触达后续硬件
    FakeWire w; w.failFirstBegin = true;
    Result r = run(w);
    EXPECT(r.halted && r.haltName == "Wire.begin");
    EXPECT(!Wire.called("setBufferSize(512)"));
    EXPECT(pinModeCalls.empty());
  }
  { // S2 512B 扩容成功 → 正常返回；缓冲 512 可用；不注销总线
    Result r = run(FakeWire());
    EXPECT(!r.halted);
    EXPECT(Wire.usable(512) && Wire.busInit);
    EXPECT(!Wire.called("end"));
    EXPECT(!pinModeCalls.empty());                  // 进入后续硬件初始化
  }
  { // S3 512 分配失败、256 恢复成功 → end → set256 → begin；缓冲 256 可用
    FakeWire w; w.failSet512 = true;
    Result r = run(w);
    EXPECT(!r.halted);
    EXPECT(Wire.usable(256) && Wire.busInit);
    EXPECT(Wire.called("end") && Wire.called("setBufferSize(256)"));
    EXPECT(!pinModeCalls.empty());
    // 调用顺序：end 必须在 setBufferSize(256) 之前（先注销再重建）
    auto& c = Wire.calls;
    auto iEnd = std::find(c.begin(), c.end(), "end");
    auto i256 = std::find(c.begin(), c.end(), "setBufferSize(256)");
    EXPECT(iEnd != c.end() && i256 != c.end() && iEnd < i256);
  }
  { // S4 end() 失败 → halt("Wire recovery")；不得调用 set256 或再次 begin
    FakeWire w; w.failSet512 = true; w.failEnd = true;
    Result r = run(w);
    EXPECT(r.halted && r.haltName == "Wire recovery");
    EXPECT(!Wire.called("setBufferSize(256)"));
    EXPECT(std::count(Wire.calls.begin(), Wire.calls.end(), "begin") == 1);  // 仅首次
    EXPECT(pinModeCalls.empty());
  }
  { // S5 set256 失败 → halt；不得再次 begin
    FakeWire w; w.failSet512 = true; w.failSet256 = true;
    Result r = run(w);
    EXPECT(r.halted && r.haltName == "Wire recovery");
    EXPECT(std::count(Wire.calls.begin(), Wire.calls.end(), "begin") == 1);
    EXPECT(pinModeCalls.empty());
  }
  { // S6 256B begin() 失败 → halt；不得进入后续硬件初始化
    FakeWire w; w.failSet512 = true; w.failBeginAfterEnd = true;
    Result r = run(w);
    EXPECT(r.halted && r.haltName == "Wire recovery");
    EXPECT(pinModeCalls.empty());
  }
  std::puts("wire-startup ok");
  return 0;
}
