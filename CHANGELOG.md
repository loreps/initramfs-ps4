# Changelog

## Unreleased

### Internal install tells you what actually failed / Установка на внутренний диск говорит, что именно сломалось

**English**

- `install-linux-int.sh` creates `/ps4hdd/app` only after the internal drive is really mounted. Before, a failed `ps4hdd_open` left the image in the initramfs RAM disk instead of on the PS4 drive.
- Before `mkfs`, the installer detaches loop devices that still point at `linux.img` (new `ps4_release_image` helper in `functions/40-install.sh`). A leftover loop makes `mkfs` answer "... is mounted" and refuse to create the filesystem, and `-f` does not override that check.
- If `mkfs` fails, the installer now prints what `mkfs` itself said instead of a bare "Could not create the file system".
- If extraction fails, the error names the archive and its size and states that the archive is corrupt or incomplete.
- The free-space value taken from `df` is validated, so an empty or non-numeric result gives a clear error instead of a broken size prompt.

**Русский**

- `install-linux-int.sh` создаёт `/ps4hdd/app` только после того, как внутренний диск реально смонтирован. Раньше при сбое `ps4hdd_open` образ создавался в RAM-диске initramfs, а не на диске PS4.
- Перед `mkfs` установщик отцепляет loop-устройства, которые всё ещё указывают на `linux.img` (новый хелпер `ps4_release_image` в `functions/40-install.sh`). Оставшийся loop заставляет `mkfs` ответить «... is mounted» и отказаться создавать файловую систему, причём `-f` эту проверку не отменяет.
- Если `mkfs` упал, установщик печатает то, что сказал сам `mkfs`, вместо безликого «Could not create the file system».
- Если распаковка упала, ошибка называет архив и его размер и говорит, что архив битый или недокачанный.
- Значение свободного места из `df` проверяется, поэтому пустой или нечисловой результат даёт понятную ошибку вместо кривого приглашения размера.

Nothing else changed: behaviour on a clean drive is the same, and external (USB) install is untouched.
Больше ничего не менялось: на чистом диске поведение прежнее, установка на USB не тронута.
