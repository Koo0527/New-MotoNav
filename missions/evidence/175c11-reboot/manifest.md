# 175c11-reboot 证据制品清单（manifest）

生成：2026-11-04 晚（175c.15 整改）。ELF 压缩归档均为 `gzip -9 -n`（确定性：无 mtime/无文件名），
原始未压缩 ELF 留存本目录磁盘但**不入 git**；bin 为明文入 git。验收方法：`gunzip -c <gz> | shasum -a 256`
须等于表中 ELF SHA256；bin 内嵌 ELF SHA256（app_desc @0x20+144 原始 32 字节，本 SDK 魔数
`0xABCD5432`）须等于同版本 ELF SHA256。

| 版本 | ELF SHA256（原始=解压后=bin 内嵌） | app bin SHA256 | ELF 归档 | bin 文件 | 构建上下文 |
|---|---|---|---|---|---|
| 175c.12diag | `d50ffab87dd86d8f92f054244cbbc6270b909b9cc0343955ac4db39072a2a770` | `8d0721f217b6a54fcaa840c5627c4fe0b5b538f4e327020b9c4d8ea6bdc6804f` | **ELF 已遗失**（构建路径被覆盖、当时未归档；哈希自 bin 内嵌字段恢复） | motonav-175c12diag-app.bin | 诊断版（两次触发 + coredump2.elf 内嵌 `d50ffab87` 即此版） |
| 175c.13 | `a0ade6ce28d50ab08b53aa3fb604aa54cf48dcfe76faeaa93c36b7a97367ee89` | `b7af272edbe866e8e6fe328cfadffc3f67905c633a0561627c4516895f4f3cbd` | motonav-175c13.elf.gz（归档 SHA256 `9fade4b01db3d94ecf2fcddae1ea666ae3bde0a046e4952e231018ae1e717ced`；ELF 为 175c.14 时期从被覆盖前 `.build` 抢救） | motonav-175c13-app.bin | 整改代码对应提交 2aeaa9d；**实际构建时树含用户 WIP**，未留存完整构建源码快照，不声明干净树、不声明可精确重建 |
| 175c.14 | `52e32551eb55b60802e862a104abd047284433e1064b722ff8b590f67e5865b7` | `a45951a58952269f8d934b6685b4ad58b66f60de21902e079e9d5c1f7f924644` | motonav-175c14.elf.gz（归档 SHA256 `c29fa2f01b154a18f6d4182745473fb5ab02766f546c994b0f1fe1bec7c1447c`） | motonav-175c14-app.bin（提交 f19e758） | 提交 f19e758 + 用户 WIP 未提交（构建时树 dirty） |
| 175c.15 | `50dda7ce8767b81321d27d7bbeb2048ba850f252056281bf6a8e1bf05275ffc2` | `e2d4d64a2d0655c1a88dedd840671f321594c4d95fb10237d3a513a372508ad2` | motonav-175c15.elf.gz（归档 SHA256 `cab3348a4bdb40ab8b2c02e5d95b5a04881c3182dfbbbb676acb82f00b2282fb`） | motonav-175c15-app.bin | 构建 HEAD = `f19e758749cbc7c0ce9c3546672a6159a45ed761`（`d4b4041^`，即 .15 改动未提交时构建）+ 用户 WIP（构建时树 dirty） |

补充说明：
- **.13fixdiag**（app bin SHA256 前缀 `cafad5a7da29f42d`，保留在 dist）：完整 ELF SHA256 自 bin 内嵌字段恢复为
  `72b76ee8e8ec959d61ae44f5c391e0ace994dadae7fff3374383d79eaf9ac813`——ELF 本体与 .12diag ELF 同样已遗失（构建路径被覆盖、当时未归档）。
- `coredump2.bin/.elf` 为事件 2 部分转储，`ESP_CORE_DUMP_INFO` 内嵌构建哈希截断为 9 位 `d50ffab87`，指向 .12diag。
- 旧档案中"可凭提交 2aeaa9d 精确重建 .12diag/.13fixdiag 诊断 ELF"的说法不成立：当时构建树混有用户 WIP，未留存源码快照，重建不保证字节一致——已从档案中删除该表述。
