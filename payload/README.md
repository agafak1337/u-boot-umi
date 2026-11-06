# EFI payload

Сюда можно положить `xnuloader.efi` (или другое PE/COFF EFI-приложение),
чтобы упаковать его в образ как Android ramdisk:

```sh
PAYLOAD=payload/xnuloader.efi bash scripts/build.sh
```

или в GitHub Actions передать `payload_url` при `Run workflow`.

При старте U-Boot возьмёт адрес и размер из `prevbl_initrd_start_addr` /
`prevbl_initrd_size` и выполнит:

```
bootefi ${prevbl_initrd_start_addr}:${prevbl_initrd_size} ${fdtcontroladdr}
```

Без payload в ramdisk лежат 5 байт `dummy`, и U-Boot сразу переходит в fastboot.

Альтернатива без пересборки — загрузить EFI-файл по USB:

```sh
fastboot stage xnuloader.efi
fastboot oem run "bootefi $fastboot_addr_r:$filesize $fdtcontroladdr"
```

Напоминание: `xnuloader.efi` из HakiOS использует Qualcomm-специфичные
UEFI-протоколы (USB device, charger, CPU), которых в U-Boot нет. Запуститься
он может, но его USB/fastboot-канал и зарядка работать не будут. Подробности
в корневом `README.md`.