#!/usr/bin/env python3
"""TDD regression for fastPush transaction lifetime and SPI ownership.

The test compiles the production fastFlushFatal/fastPush/flushTask bodies against
a fault-injecting SPI layer. When a polling transaction is still in flight, the
fatal restart path must read the live stack descriptor and DMA buffer; the old
return-then-restart path is a stack-use-after-return under ASan.
"""
import os, pathlib, re, subprocess, tempfile

root = pathlib.Path(__file__).resolve().parents[3]
source = (root / "firmware/boards/175/MotoNav/src/display/DisplayPipeline.h").read_text()
match = re.search(r'(?:void|bool) __attribute__\(\(optimize\("O3"\)\)\) fastPush\(const uint16_t \*fb\)', source)
if not match:
    raise SystemExit("fastPush signature not found")
# After the fix the fatal restart helper precedes fastPush; before it, flushTask
# still owns the restart code. Extract whichever production shape exists.
fatal = source.find("[[noreturn]] void fastFlushFatal")
start = fatal if fatal != -1 else match.start()
end = source.index("\nvoid flushWait()", start)
fast = source[start:end]

stubs = r'''
#include <cassert>
#include <cstdint>
#include <cstdlib>
#include <cstring>

#define LCD_WIDTH 4
#define LCD_HEIGHT 8
#define FAST_PIX 16
#define LCD_CS 10
#define HIGH 1
#define LOW 0
#define portMAX_DELAY 1000
#define pdTRUE 1
#define ESP_OK 0
#define ESP_FAIL -1
#define ESP_ERR_INVALID_STATE 0x103
#define ESP_ERR_TIMEOUT 0x107
#define SPI_TRANS_MODE_QIO 1u
#define SPI_TRANS_VARIABLE_CMD 2u
#define SPI_TRANS_VARIABLE_ADDR 4u
#define SPI_TRANS_VARIABLE_DUMMY 8u

typedef int esp_err_t;
struct spi_transaction_t {
    uint32_t flags;
    uint16_t cmd;
    uint64_t addr;
    size_t length;
    void *tx_buffer;
};
struct spi_transaction_ext_t { spi_transaction_t base; };
typedef void *spi_device_handle_t;

struct Panel {
    void startWrite() {}
    void writeAddrWindow(int, int, int, int) {}
    void endWrite() {}
    void draw16bitRGBBitmap(int, int, const uint16_t *, int, int) {}
};
Panel panelObj;
Panel *panel = &panelObj;
int16_t rotSpan[LCD_HEIGHT] = {};
bool rotFree = false;
int screenRot = 0;
int32_t rotCos = 1, rotSin = 0;
spi_device_handle_t fastDev = (void *)1;
uint8_t *fastBuf[2] = {};
uint16_t fb[LCD_WIDTH * LCD_HEIGHT] = {};
uint16_t *volatile flushSrc = fb;
volatile uint32_t flushMsAcc = 0, flushCnt = 0;
namespace QuarterTurnBlit { inline void pack(uint16_t *, const uint16_t *, int, int, int, int) {} }
static inline uint32_t rgbSpread(uint16_t c) { return c; }
int csLevel = HIGH;
void digitalWrite(int pin, int level) { if (pin == LCD_CS) csLevel = level; }

bool fastFlushOn = true;
int flushReq = 1, flushDone = 1;
int fastFlushFaultStage = 0;
int fastFlushError = 0;

struct Restart {};
struct Stop {};
int resets = 0;
int takeCalls = 0;
int givesDone = 0;
int xSemaphoreTake(int, int) {
    ++takeCalls;
    if (takeCalls == 1) return pdTRUE;   // let flushTask take one request
    throw Stop{};                         // normal path: leave the infinite worker loop
}
void xSemaphoreGive(int) { ++givesDone; }
uint32_t millis() { static uint32_t t = 0; return t += 1000; }
void delay(int) {}
struct ESPStub { void restart() { ++resets; throw Restart{}; } };
ESPStub ESP;

struct SerialT {
    template <typename... T> void printf(const char *, T...) {}
    template <typename... T> void println(T...) {}
};
SerialT Serial;

int acquireStatus = ESP_OK;
int startStatus = ESP_OK;
int endStatus[8] = {};
int starts = 0, ends = 0, releases = 0;
bool inFlight = false;
spi_transaction_t *lastTrans = nullptr;

esp_err_t spi_device_acquire_bus(spi_device_handle_t, int) {
    assert(!inFlight);
    return acquireStatus;
}
void spi_device_release_bus(spi_device_handle_t) {
    // ESP-IDF asserts when the bus is released while a polling transaction is in flight.
    assert(!inFlight);
    ++releases;
}
esp_err_t spi_device_polling_start(spi_device_handle_t, spi_transaction_t *trans, int) {
    assert(!inFlight);
    ++starts;
    lastTrans = trans;
    if (startStatus == ESP_ERR_INVALID_STATE) {      // stale polling transaction from the device
        inFlight = true;
        return startStatus;
    }
    if (startStatus != ESP_OK) return startStatus;  // rejected before the transaction was committed
    inFlight = true;
    return ESP_OK;
}
esp_err_t spi_device_polling_end(spi_device_handle_t, int) {
    assert(inFlight);
    ++ends;
    const esp_err_t err = endStatus[ends - 1];
    // ESP-IDF v5.5.4: timeout and unknown completion states leave the
    // transaction (and its descriptor) in flight. Success and the DMA-failure
    // error are returned after the descriptor was reclaimed.
    if (err == ESP_OK || err == ESP_ERR_INVALID_STATE) inFlight = false;
    return err;
}
void saveAndRestart(const char *, int, bool) {
    ++resets;
    if (inFlight) {
        // The fatal restart must read the still-live descriptor and DMA buffer.
        // Before the fix this read is stack-use-after-return.
        assert(lastTrans != nullptr);
        assert(lastTrans->length > 0);
        assert(lastTrans->tx_buffer == fastBuf[0] || lastTrans->tx_buffer == fastBuf[1]);
        volatile uint8_t sample = ((const volatile uint8_t *)lastTrans->tx_buffer)[0];
        (void)sample;
    }
    throw Restart{};
}
'''

test = r'''
int runFlush() {
    try { flushTask(nullptr); }
    catch (const Restart &) { return 1; }
    catch (const Stop &) { return 0; }
    return -1;
}
void reset() {
    acquireStatus = ESP_OK;
    startStatus = ESP_OK;
    starts = ends = releases = 0;
    csLevel = HIGH;
    inFlight = false;
    lastTrans = nullptr;
    fastFlushFaultStage = fastFlushError = 0;
    takeCalls = resets = givesDone = 0;
    for (int i = 0; i < 8; ++i) endStatus[i] = ESP_OK;
}
int main() {
    for (int i = 0; i < 2; ++i) fastBuf[i] = (uint8_t *)calloc(FAST_PIX, 2);

    reset();
    assert(runFlush() == 0);
    assert(starts == 2 && ends == 2 && releases == 1 && csLevel == HIGH && !inFlight);
    assert(givesDone == 1 && resets == 0);

    reset();
    acquireStatus = ESP_FAIL;
    assert(runFlush() == 1);
    assert(starts == 0 && ends == 0 && releases == 0 && csLevel == HIGH && !inFlight);
    assert(fastFlushFaultStage == 1 && fastFlushError == ESP_FAIL);
    assert(resets == 1 && givesDone == 0);

    reset();
    startStatus = ESP_FAIL;
    assert(runFlush() == 1);
    assert(starts == 1 && ends == 0 && releases == 1 && csLevel == HIGH && !inFlight);
    assert(fastFlushFaultStage == 2 && fastFlushError == ESP_FAIL);
    assert(resets == 1 && givesDone == 0);

    // A previous polling transaction is still active: polling_start rejects the
    // new one with ESP_ERR_INVALID_STATE and the stale transaction still owns
    // CS/bus. The descriptor must stay valid through the fatal restart.
    reset();
    startStatus = ESP_ERR_INVALID_STATE;
    assert(runFlush() == 1);
    assert(starts == 1 && ends == 0 && releases == 0 && csLevel == LOW && inFlight);
    assert(fastFlushFaultStage == 2 && fastFlushError == ESP_ERR_INVALID_STATE);
    assert(resets == 1 && givesDone == 0);

    // Timeout: the transaction may still be in flight. Do not start the next
    // one, do not raise CS, do not release the bus; restart from fastPush
    // while the descriptor is still alive.
    reset();
    endStatus[0] = ESP_ERR_TIMEOUT;
    assert(runFlush() == 1);
    assert(starts == 1 && ends == 1 && releases == 0 && csLevel == LOW && inFlight);
    assert(fastFlushFaultStage == 3 && fastFlushError == ESP_ERR_TIMEOUT);
    assert(resets == 1 && givesDone == 0);

    // The only polling_end error returned after the DMA descriptor was
    // reclaimed: ownership can be returned normally, then the caller restarts.
    reset();
    endStatus[0] = ESP_ERR_INVALID_STATE;
    assert(runFlush() == 1);
    assert(starts == 1 && ends == 1 && releases == 1 && csLevel == HIGH && !inFlight);
    assert(fastFlushFaultStage == 3 && fastFlushError == ESP_ERR_INVALID_STATE);
    assert(resets == 1 && givesDone == 0);

    // Any other completion error is ambiguous: keep CS/bus and the descriptor
    // for the fatal restart.
    reset();
    endStatus[0] = ESP_FAIL;
    assert(runFlush() == 1);
    assert(starts == 1 && ends == 1 && releases == 0 && csLevel == LOW && inFlight);
    assert(fastFlushFaultStage == 3 && fastFlushError == ESP_FAIL);
    assert(resets == 1 && givesDone == 0);

    for (int i = 0; i < 2; ++i) free(fastBuf[i]);
    return 0;
}
'''

code = stubs + "\n" + fast + "\n" + test
with tempfile.TemporaryDirectory() as d:
    path = pathlib.Path(d) / "fastpush.cpp"
    path.write_text(code)
    binary = pathlib.Path(d) / "fastpush"
    env = dict(os.environ, ASAN_OPTIONS="detect_stack_use_after_return=1:halt_on_error=1")
    subprocess.run(["clang++", "-std=c++17", "-Wno-unknown-attributes",
                    "-fsanitize=address", "-fsanitize-address-use-after-return=always",
                    str(path), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, env=env)
print("fastPush/flushTask transaction lifetime, single-in-flight polling and failure ownership regression passed")
