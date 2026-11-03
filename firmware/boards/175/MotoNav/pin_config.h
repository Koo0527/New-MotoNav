#pragma once

#define XPOWERS_CHIP_AXP2101

#define LCD_SDIO0 4
#define LCD_SDIO1 5
#define LCD_SDIO2 6
#define LCD_SDIO3 7
#define LCD_SCLK 38
#define LCD_CS 12
#define LCD_RESET 39
#define LCD_WIDTH 466
#define LCD_HEIGHT 466

// TOUCH
#define IIC_SDA 15
#define IIC_SCL 14
#define TP_INT 11
#define TP_RESET 40

// ES8311
#define I2S_MCK_IO 16
#define I2S_BCK_IO 9
#define I2S_DI_IO 10
#define I2S_WS_IO 45
#define I2S_DO_IO 8

// v7.x 删除了与上面 I2S_* 引脚冲突且无任何代码引用的裸引脚块
// （MCLKPIN 42 / BCLKPIN 9 / WSPIN 45 / DOPIN 10 / DIPIN 8）——接音频前先统一用 I2S_* 这组。
#define PA                  46

// SD
const int SDMMC_CLK = 2;
const int SDMMC_CMD = 1;
const int SDMMC_DATA = 3;
const int SDMMC_CS = 41;