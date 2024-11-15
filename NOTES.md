# Capturing a clean dump

Restore the device to stock.
Use the supertool to set the uboot variables to format as ext2/ext4.

```sh
superbird-tool.py --burn_mode
superbird-tool.py --bulkcmd "amlmmc env"
superbird-tool.py --bulkcmd "setenv firstboot 1"
superbird-tool.py --bulkcmd "saveenv"
```

Run the bulkcmd dump script.

```sh
./scripts/dump.sh
```

Rename the dump files:

* system_a.dump -> system_a.ext2
* system_b.dump -> system_b.ext2
* settings.dump -> settings.ext4
* data.dump -> data.ext4

Put the files in the `stock` directory and run the build script.

```sh
./build_image.sh ./stock
```
