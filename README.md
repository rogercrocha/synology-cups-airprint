# synology-cups-airprint

[Português](README.pt-BR.md)

> **AI disclosure:** this project was built with the help of AI (Claude, by
> Anthropic). The setup was tested by the author on his own Synology NAS,
> Brother printer, iPhone and Mac.

AirPrint for a network printer that does not support it, served by CUPS in a
Docker container on a Synology NAS. iPhones, iPads and Macs find the printer
on their own, and the **color / black & white** and **two-sided** toggles in
the iOS and macOS print dialogs actually work.

Built and tested with a Brother MFC-9460CDN (PCL6 / BR-Script3, no IPP), a
Synology NAS on DSM 7 (aarch64), Debian 13 "trixie" (CUPS 2.4.10), iOS and
macOS. It should work with any printer that has a Foomatic/Ghostscript driver
and with any Docker host that allows host networking.

## Why this exists

Getting a queue to *appear* on an iPhone is easy. Getting it to behave took
fixing four problems that are each documented somewhere, but rarely together:

1. **The black & white toggle is ignored.** CUPS advertises
   `print-color-mode-supported = monochrome,color`, the toggle shows up, and
   every job still prints in color. Stock CUPS 2.4 maps `print-color-mode` to
   a PPD option only through presets, and when a PPD has no
   `*APPrinterPreset`, it auto-creates the grayscale preset only if
   `ColorModel` has a choice named exactly `Gray`. Foomatic PPDs name it
   `Grayscale`, so nothing is mapped. Ubuntu's CUPS carries a patch that
   hides this; Debian's does not. The entrypoint appends explicit presets to
   the queue's PPD.
2. **iOS shows "Gathering printer information" and the printer disappears.**
   iOS prefers IPPS. CUPS creates its self-signed certificate in
   `/etc/cups/ssl`, but a volume mounted on `/etc/cups` replaces the image's
   directory, the folder does not exist, and every TLS handshake fails with
   `Unable to create server credentials`. The entrypoint creates it.
3. **One tap prints the same page again and again.** With
   `PreserveJobHistory No`, CUPS purges a job as soon as it finishes. iOS
   then asks for the job's status, gets "not found", decides the job was lost
   and sends it again. The config keeps job history for one hour.
4. **DSM does not run avahi**, so the container runs its own dbus and avahi
   with host networking.

## Will it work with my printer?

Probably, if all of these hold:

- **The NAS can reach the printer** over the network: raw socket (port
  9100), LPD (`lpd://`) or IPP. USB printers are not covered here.
- **There is a driver for it in the image.** The image ships CUPS's generic
  drivers and `foomatic-db` (the Ghostscript drivers, such as `pxlcolor`,
  `pxlmono` and `ljet4`). Other families need one extra Debian package in
  the `apt-get install` line of the `Dockerfile`, then a rebuild:
  `hplip` for HP, `printer-driver-brlaser` for many Brother lasers,
  `printer-driver-splix` for Samsung and Xerox, `printer-driver-gutenprint`
  for many inkjets. List what is available with
  `sudo docker exec cups-airprint lpinfo -m`.
- **The driver runs on your NAS's CPU.** Vendor binary drivers built only
  for x86 do not run on ARM models.

About the black & white toggle: the fix in this repository applies to PPDs
whose `ColorModel` option has a `Grayscale` choice (Foomatic). For other
PPDs, CUPS maps the toggle by itself when the gray choice is one it knows
(`ColorModel=Gray`, HP's `grayscale`, Brother's `BRMonoColor=Mono` and a few
others); if not, the toggle may appear and do nothing.

If your printer already supports AirPrint or IPP Everywhere, you do not need
this at all.

So far it has been tested with one printer, the Brother MFC-9460CDN. Reports
with other models, working or not, are welcome as issues.

## Requirements

- Synology NAS with DSM 7 and **Container Manager** (or any Linux host with
  Docker and Compose).
- SSH access to the NAS with an administrator account.
- The printer on the network with a fixed IP (a DHCP reservation is enough)
  and raw socket printing on port 9100.
- DSM's own printer server turned off (port 631 must be free).

## Installation

1. Download this repository to your home folder on the NAS. DSM has no `git`
   unless you install the Git Server package, but `curl` works:

   ```bash
   cd ~ && curl -L https://github.com/rogercrocha/synology-cups-airprint/archive/refs/heads/main.tar.gz | tar xz \
     && mv synology-cups-airprint-main synology-cups-airprint
   ```
2. Find the driver for your printer. After the first build you can list
   them with `sudo docker exec cups-airprint lpinfo -m | grep -i <model>`;
   a close model from the same family usually works.
3. Run the deploy script once. It creates `.env` from `.env.example` and stops:

   ```bash
   cd ~/synology-cups-airprint && sudo bash deploy.sh
   ```

4. Edit `/volume1/docker/synology-cups-airprint/.env` (at least
   `PRINTER_URI`, `PRINTER_PPD` and `QUEUE_NAME`) and run the script again.
   It builds the image, starts the container, creates the queue and shows
   what the iPhone will see. A random password for the web interface is
   written to `.env` if you left `change-me`.

Pick the entry whose name ends in **"@ <your NAS name>"** on the iPhone or
Mac. If the printer also announces itself, the entry without the suffix is
the printer, not this server.

## Settings (`.env`)

| Variable | Example | Meaning |
|---|---|---|
| `PRINTER_URI` | `socket://192.168.1.50:9100` | How CUPS reaches the printer |
| `PRINTER_PPD` | `foomatic:Brother-HL-4050CDN-pxlcolor.ppd` | Driver, from `lpinfo -m` |
| `QUEUE_NAME` | `Brother_MFC-9460CDN` | Queue name, no spaces |
| `QUEUE_DESC` | `Brother MFC-9460CDN` | Name shown on the devices |
| `PRINTER_LOCATION` | `Home` | Location text |
| `PAGE_SIZE` | `A4` | Default paper size |
| `COLOR_DEFAULT` | `color` | Default for jobs that do not say (macOS opens the dialog with it) |
| `CUPS_USER` / `CUPS_PASSWORD` | `print` | Login for `http://<NAS-IP>:631` |

Settings that create the queue are applied only when the queue does not
exist yet. To start over, stop the container and move the `config` folder
away.

## Testing the color mapping

```bash
sudo docker exec cups-airprint cupsctl LogLevel=debug2
sudo docker exec cups-airprint sh -c "printf '%%!PS\n1 0 0 setrgbcolor 72 72 200 200 rectfill showpage\n' | lp -d <QUEUE_NAME> -o print-color-mode=monochrome"
sudo docker exec cups-airprint sh -c 'grep -aoE "Adding preset option [^ ]+|sDEVICE=[a-z]+" /var/log/cups/error_log'
sudo docker exec cups-airprint cupsctl LogLevel=warn
```

You should get a gray square on paper, and in the log
`Adding preset option ColorModel=Grayscale` and a monochrome Ghostscript
device (for this Brother, `pxlmono`). Use a light page like this one for
tests: the CUPS color test page at 600 dpi was heavy enough to make this
printer reboot.

## Troubleshooting

- **The printer vanished from the devices after changing the queue with
  `lpadmin`.** CUPS re-registers the Bonjour service, and avahi inside the
  container sometimes stops answering browse queries for it, although the
  service still resolves by name. `sudo docker restart cups-airprint` fixes
  it.
- **Black & white still prints in color.** Check that the queue's PPD has
  presets: `sudo docker exec cups-airprint grep -c APPrinterPreset /etc/cups/ppd/<QUEUE_NAME>.ppd`.
  Presets are only added when `ColorModel` has a `Grayscale` choice; other
  drivers may need other option names.
- **"Gathering printer information" on iOS.** Look for
  `Unable to create server credentials` in `/var/log/cups/error_log` and
  check that `/etc/cups/ssl` exists inside the container.
- **The same job prints several times.** Make sure `PreserveJobHistory` is
  not `No` in `/etc/cups/cupsd.conf`.

## Limitations

- CUPS 3 drops PPD support. This setup depends on PPDs; the long-term
  replacement is a Printer Application such as `ghostscript-printer-app`,
  which today is published for arm64 only as a snap.
- `/admin` is reachable from the whole LAN, protected by the password in
  `.env`. Do not forward port 631 to the internet.

## License

[MIT](LICENSE)
