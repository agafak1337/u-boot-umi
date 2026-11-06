# U-Boot для Xiaomi Mi 10 (umi)

Порт mainline U-Boot на Xiaomi Mi 10 (`umi`, Snapdragon 865 / SM8250 «kona»).
Собирается в GitHub Actions, упаковывается в Android boot image и запускается
через `fastboot boot` — без прошивки разделов.

База: U-Boot `v2027.01-rc1`. В нём есть generic-поддержка Qualcomm-телефонов
(`qcom_defconfig` + `qcom-phone.config`): SM8250 clocks/pinctrl, UFS, DWC3 USB2
gadget, fastboot, RPMH-регуляторы, кнопки, bootmenu, `bootefi`, а также разбор
DRAM из SMEM (`arch/arm/mach-snapdragon/dram.c`). Тег `v2026.10` тоже умеет
qcom-phone, но SMEM-разбора памяти там ещё нет, поэтому он не подходит для DT
без узла `/memory`.

**Ни сборка, ни запуск ещё не проверялись.** Это заготовка порта: все шаги
скриптованы, но первый прогон CI и первый запуск на телефоне — это bring-up,
а не готовый продукт.

## Важно: это не замена Mu-Silicium

`xnuloader.efi` из HakiOS — не обычное EFI-приложение. Он работает с железом
через Qualcomm-специфичные протоколы, которых в U-Boot нет:

- `EFI_USB_DEVICE_PROTOCOL` (`d9d9ce48-...`) — polled USB device/fastboot API;
- `EFI_QCOM_CHARGER_EX_PROTOCOL` / charger protocol — зарядка и батарея;
- CPU architectural protocol — hook исключений.

Поэтому `bootefi xnuloader.efi` **запустит код**, но USB-канал fastboot, зарядка
и часть инициализации не заработают: `xnuloader` общается с Mu-Silicium, а не с
U-Boot. Чтобы это исправить, в U-Boot нужен шим на эти протоколы (отдельный
большой проект). Если цель — HakiOS, практичнее оставить Mu-Silicium.

Этот порт полезен как самостоятельный U-Boot: меню, fastboot, консоль на экране,
UFS, запуск обычных EFI-приложений и Linux.

## Что должно работать

| Есть | Оговорка |
|---|---|
| Старт U-Boot из `fastboot boot` | ABL загружает `u-boot.bin` как kernel |
| Экран: `simple-framebuffer` в `cont_splash` XBL | 0x9C000000, 1080x2340, 32 bpp |
| USB2 DWC3 gadget + fastboot | UFS-бэкенда у fastboot нет, только `fastboot boot` |
| Bootmenu, кнопки, `fastboot oem console` | зависит от PMIC/GPIO в DTS |
| UFS (`scsi scan`, `part list`) | U-Boot UFS/QMP PHY из qcom_defconfig |
| `bootefi` обычных PE/COFF EFI-приложений | не QCOM-протокольных |
| Загрузка EFI-payload из ramdisk | ABL кладёт адрес/размер в `prevbl_initrd_*` |

## Сборка в GitHub Actions

Тулчейн на своей машине не нужен.

```sh
cd u-boot-umi
git init -b main
git add .
git commit -m "U-Boot port for Xiaomi Mi 10 (umi)"
gh repo create u-boot-umi --private --source=. --push
```

Или создай репозиторий на github.com и запушь вручную. Дальше:

1. **Actions → build-u-boot-umi → Run workflow** (или просто push в `main`).
2. Скачай артефакт **u-boot-umi**.
3. В нём: `u-boot-umi.img` (то, что грузим), `u-boot.bin`, `u-boot.dtb`,
   `.config`, `build-info.txt`.

У `workflow_dispatch` есть два необязательных поля:

- `uboot_tag` — тег U-Boot (по умолчанию `v2027.01-rc1`);
- `payload_url` — прямая ссылка на EFI-приложение (например, `loader.efi`).
  Оно будет упаковано как Android ramdisk, и U-Boot попробует его запустить.

Если `payload_url` пустой, в ramdisk лежат 5 байт `dummy` — ровно как в
Mu-Silicium; ABL всё равно публикует `linux,initrd-start`/`linux,initrd-end`.

## Локальная сборка (Linux x86-64)

```sh
sudo apt-get install -y build-essential bison flex libssl-dev libgnutls28-dev \
  uuid-dev swig python3 python3-dev python3-setuptools python3-pyelftools \
  gcc-aarch64-linux-gnu device-tree-compiler bc git gzip curl

UBOOT_TAG=v2027.01-rc1 bash scripts/build.sh
```

Результат: `build/out/u-boot-umi.img`.

Переопределяемые переменные: `UBOOT_TAG`, `UBOOT_URL`, `BUILD_DIR`,
`CROSS_COMPILE`, `JOBS`, `PAYLOAD`, `MKBOOTIMG` (см. шапку `scripts/build.sh`).

## Запуск на телефоне

Нужен разблокированный загрузчик и `adb`/`fastboot`.

```sh
adb reboot bootloader
fastboot boot build/out/u-boot-umi.img
```

U-Boot попробует EFI-payload из ramdisk (если он там есть), затем поднимет
fastboot на USB:

```sh
fastboot devices          # должен появиться U-Boot
fastboot oem console      # выгрузить записанный лог консоли
fastboot oem run "printenv"
fastboot oem run "scsi scan; part list"
```

Запустить EFI-приложение без пересборки образа:

```sh
fastboot stage loader.efi
fastboot oem run "bootefi $fastboot_addr_r:$filesize $fdtcontroladdr"
```

`$filesize` выставляет сам fastboot после `stage`, поэтому размер передаётся
явно — иначе `bootefi` не знает, сколько байт в образе.

Вернуться в Android: `fastboot reboot` (или удерживать Power).

**Не делай `fastboot flash` в UFS**: у fastboot в U-Boot сейчас нет UFS-бэкенда.
`fastboot boot` — безопасный путь, разделы не меняются. Прошивка в `recovery`
(как в HakiOS) возможна только после того, как экран и USB проверены, и после
бэкапа своего recovery.

## Если экран чёрный

Скорее всего U-Boot уже работает, просто не попал в framebuffer:

```sh
fastboot devices
fastboot oem console                 # весь лог U-Boot
fastboot oem run "fdt print /chosen" # что U-Boot видит про framebuffer
```

Что проверить в первую очередь:

1. `fdt print /chosen/framebuffer@9c000000` — `width`/`height`/`stride`;
2. `fdt print /reserved-memory` — регион `cont-splash@9c000000`;
3. `clk dump` — живы ли SM8250 clocks.

Если USB тоже молчит: удерживай **Power + Volume Down** до перезагрузки в
stock fastboot и запусти образ снова.

## Как это устроено

```
u-boot-umi/
├─ .github/workflows/build.yml        сборка на Ubuntu 24.04
├─ board/qualcomm/umi.config          Kconfig-фрагмент (после qcom-phone.config)
├─ board/qualcomm/umi.env             env: сначала EFI-payload, потом fastboot
├─ dts/upstream/src/arm64/qcom/
│  └─ sm8250-xiaomi-umi.dts           лёгкий overlay на elish (тот же SM8250)
├─ patches/0001-save-prevbl-initrd-size.patch
│                                     сохраняет размер initrd для bootefi
├─ scripts/build.sh                   clone U-Boot → патч → сборка → mkbootimg
└─ payload/                           сюда можно положить *.efi (не в git)
```

Ключевые решения:

- **DT берётся из upstream-зеркала U-Boot** и включает
  `sm8250-xiaomi-elish-common.dtsi` (Xiaomi Mi Pad 5 Pro, тот же SM8250,
  PM8150/8150B/8150L + PM8009). Для umi переопределены `model`, `compatible`,
  `chassis-type` и геометрия кадра 1080x2340. UFS/USB/регуляторы — общие.
- **Память**: в DT нет `/memory`. U-Boot берёт карту из SMEM
  (`arch/arm/mach-snapdragon/dram.c`), поэтому 8/12 ГБ определяются на телефоне,
  а не хардкодятся.
- **Framebuffer**: XBL оставляет splash в `Display Reserved` (0x9C000000,
  0x2300000). `simple-framebuffer` в `/chosen` смотрит туда; `no-map` с
  `cont_splash_mem` снят, иначе U-Boot не смог бы туда писать. От LMB регион
  защищён `/memreserve/`.
- **Образ**: `gzip(u-boot.bin)` + `u-boot.dtb`, Android header v1 — та же схема,
  что у Mu-Silicium. `u-boot.bin` (а не `u-boot-nodtb.bin`) важен: встроенный DT
  даёт SMEM-fallback для памяти. ABL дополнительно передаёт свой FDT (это наш же
  DTB), из его `/chosen/linux,initrd-start` и `linux,initrd-end` U-Boot берёт
  `prevbl_initrd_start_addr` / `prevbl_initrd_size`.
- **Патч**: стоковый `save_prev_bl_data()` сохраняет только адрес initrd, а
  `bootefi` для сырого PE/COFF нужен ещё и размер. `patches/0001-...` добавляет
  `prevbl_initrd_size`; `scripts/build.sh` применяет патч к клону U-Boot.
  Патч локальный, не для upstream.
- **fastboot**: `qcom-phone.config` уже включает `USB_FUNCTION_FASTBOOT`,
  `CONSOLE_RECORD`, `FASTBOOT_CMD_OEM_CONSOLE`. `fastboot oem console` — главный
  инструмент отладки при чёрном экране.

## Что дальше

1. Первый запуск: `fastboot boot`, затем `fastboot oem console` — понять, где
   остановились (память, pinctrl, UFS, USB, framebuffer).
2. Если экран не тот — поправить `width`/`height`/`stride` в
   `sm8250-xiaomi-umi.dts` (например, XBL может отдать 1080x2400).
3. UFS: проверить `scsi scan` и `part list`, затем загрузку файла с ext4.
4. Для HakiOS: либо оставить Mu-Silicium, либо писать в U-Boot шим
   `EFI_USB_DEVICE_PROTOCOL` + charger/CPU протоколов; без него `xnuloader`
   не получит свой USB-канал.
5. Когда umi появится в upstream Linux, заменить elish-базу на
   `sm8250-xiaomi-umi.dts` из mainline и отправить DTS в U-Boot.

## Лицензии

U-Boot — GPL-2.0+. DTS — BSD-3-Clause, как исходный `sm8250-xiaomi-elish-common.dtsi`.
Проприетарных файлов Xiaomi/Apple в репозитории нет.