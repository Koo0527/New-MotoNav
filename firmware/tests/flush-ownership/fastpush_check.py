#!/usr/bin/env python3
"""TDD regression for the fastPush SPI transaction ownership.

The test compiles the production fastPush body against a fault-injecting SPI
layer. It must observe exactly one polling transaction in flight, no next
transaction after a failure, and CS/bus ownership released on every path.
"""
import pathlib, re, subprocess, tempfile

root = pathlib.Path(__file__).resolve().parents[3]
source = (root / "firmware/boards/175/MotoNav/src/display/DisplayPipeline.h").read_text()
match = re.search(r'(?:void|bool) __attribute__\(\(optimize\("O3"\)\)\) fastPush\(const uint16_t \*fb\)', source)
if not match:
    raise SystemExit("fastPush signature not found")
start = match.start()
end = source.index("\nvoid flushTask", start)
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

struct Panel { void startWrite(){} void writeAddrWindow(int,int,int,int){} void endWrite(){} };
Panel panelObj;
Panel *panel = &panelObj;
int16_t rotSpan[LCD_HEIGHT] = {};
bool rotFree = false;
int screenRot = 0;
int32_t rotCos = 1, rotSin = 0;
spi_device_handle_t fastDev = (void *)1;
uint16_t *fastBuf[2] = {};
uint16_t fb[LCD_WIDTH * LCD_HEIGHT] = {};
namespace QuarterTurnBlit { inline void pack(uint16_t*, const uint16_t*, int, int, int, int) {} }
static inline uint32_t rgbSpread(uint16_t c) { return c; }
int csLevel = HIGH;
void digitalWrite(int pin, int level) { if (pin == LCD_CS) csLevel = level; }

int acquireStatus = ESP_OK;
int startStatus = ESP_OK;
int endStatus[8] = {};
int starts = 0, ends = 0, releases = 0;
bool inFlight = false;
int fastFlushFaultStage = 0;
int fastFlushError = 0;

esp_err_t spi_device_acquire_bus(spi_device_handle_t, int) {
    assert(!inFlight);
    return acquireStatus;
}
void spi_device_release_bus(spi_device_handle_t) {
    // ESP-IDF asserts when the bus is released while a polling transaction is in flight.
    assert(!inFlight);
    ++releases;
}
esp_err_t spi_device_polling_start(spi_device_handle_t, spi_transaction_t *, int) {
    assert(!inFlight);
    ++starts;
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
    // ESP-IDF v5.5.4: a timeout leaves host->polling set and the transaction in flight.
    if (err == ESP_ERR_TIMEOUT) return err;
    // ESP_ERR_INVALID_STATE is only returned after the DMA descriptor was reclaimed.
    inFlight = false;
    return err;
}
struct SerialT { template <typename... T> void println(T...) {} };
SerialT Serial;
'''

test = r'''
void reset() {
    acquireStatus = ESP_OK;
    startStatus = ESP_OK;
    starts = ends = releases = 0;
    csLevel = HIGH;
    inFlight = false;
    fastFlushFaultStage = fastFlushError = 0;
    for (int i = 0; i < 8; ++i) endStatus[i] = ESP_OK;
}
int main() {
    for (int i = 0; i < 2; ++i) fastBuf[i] = (uint16_t *)calloc(FAST_PIX, sizeof(uint16_t));
    reset();
    bool ok = fastPush(fb);
    assert(ok);
    assert(starts == 2 && ends == 2 && releases == 1 && csLevel == HIGH && !inFlight);

    reset();
    acquireStatus = ESP_FAIL;
    ok = fastPush(fb);
    assert(!ok && starts == 0 && ends == 0 && releases == 0 && csLevel == HIGH && !inFlight);
    assert(fastFlushFaultStage == 1 && fastFlushError == ESP_FAIL);

    reset();
    startStatus = ESP_FAIL;
    ok = fastPush(fb);
    assert(!ok && starts == 1 && ends == 0 && releases == 1 && csLevel == HIGH && !inFlight);
    assert(fastFlushFaultStage == 2 && fastFlushError == ESP_FAIL);

    // A previous polling transaction is still active: polling_start rejects the new
    // one with ESP_ERR_INVALID_STATE and the stale transaction still owns CS/bus.
    reset();
    startStatus = ESP_ERR_INVALID_STATE;
    ok = fastPush(fb);
    assert(!ok && starts == 1 && ends == 0 && releases == 0 && csLevel == LOW && inFlight);
    assert(fastFlushFaultStage == 2 && fastFlushError == ESP_ERR_INVALID_STATE);

    // Timeout: the transaction may still be in flight. Do not start the next one,
    // do not raise CS, do not release the bus; the caller restarts.
    reset();
    endStatus[0] = ESP_ERR_TIMEOUT;
    ok = fastPush(fb);
    assert(!ok && starts == 1 && ends == 1 && releases == 0 && csLevel == LOW && inFlight);
    assert(fastFlushFaultStage == 3 && fastFlushError == ESP_ERR_TIMEOUT);

    // The only polling_end error returned after the DMA descriptor was reclaimed:
    // ownership can be returned normally, but no next transaction starts.
    reset();
    endStatus[0] = ESP_ERR_INVALID_STATE;
    ok = fastPush(fb);
    assert(!ok && starts == 1 && ends == 1 && releases == 1 && csLevel == HIGH && !inFlight);
    assert(fastFlushFaultStage == 3 && fastFlushError == ESP_ERR_INVALID_STATE);

    // Any other error is an unknown completion state: keep CS/bus ownership for the restart.
    reset();
    endStatus[0] = ESP_FAIL;
    ok = fastPush(fb);
    assert(!ok && starts == 1 && ends == 1 && releases == 0 && csLevel == LOW && !inFlight);
    assert(fastFlushFaultStage == 3 && fastFlushError == ESP_FAIL);

    for (int i = 0; i < 2; ++i) free(fastBuf[i]);
    return 0;
}
'''

code = stubs + "\n" + fast + "\n" + test
with tempfile.TemporaryDirectory() as d:
    path = pathlib.Path(d) / "fastpush.cpp"
    path.write_text(code)
    binary = pathlib.Path(d) / "fastpush"
    subprocess.run(["c++", "-std=c++17", "-Wno-unknown-attributes", str(path), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
print("fastPush single-in-flight polling and failure ownership regression passed")
