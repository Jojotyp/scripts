# Screenshot sync

Sync recent media from an Android phone over adb into script-specific local folders:

```text
~/Screenshots/<phone_name>_<adb_serial>/
~/Pictures/phone/<phone_name>_<adb_serial>/camera/
~/Pictures/phone/<phone_name>_<adb_serial>/recent/
```

## Scripts

- `sync_screenshots.sh`: pulls the last N screenshots, newest first. Defaults to N=1. It looks for screenshots in common Android screenshot folders such as `/sdcard/Pictures/Screenshots`, `/sdcard/DCIM/Screenshots`, and `/sdcard/Screenshots`.
- `sync_camera.sh`: pulls the last N camera image and video files, newest first. Defaults to N=1. It looks for camera media in common Android camera folders such as `/sdcard/DCIM/Camera`, `/sdcard/DCIM/100ANDRO`, and `/sdcard/Pictures/Camera`, then saves into `~/Pictures/phone/<phone_name>_<adb_serial>/camera/`.
- `sync_recent.sh`: pulls the last N recent image and video files, newest first. Defaults to N=1. It searches recursively under `/sdcard/DCIM` and `/sdcard/Pictures`, then saves into `~/Pictures/phone/<phone_name>_<adb_serial>/recent/`.
