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

## Motivation

My Brother MFC-9460CDN is more than ten years old and still prints well. It
just does not speak AirPrint, so the iPhone and the Mac cannot use it on
their own. Throwing away a good printer for that reason makes no sense, so I
set out to give it a second life.

First I tried the Printer Applications made for this, `ps-printer-app` and
`ghostscript-printer-app`, on a Raspberry Pi. The printer showed up on the
iPhone, but all of them had the same problem: the native black & white
toggle in iOS did nothing, and every page came out in color. Getting CUPS to
work properly on a Synology NAS was hard too, and Synology's own printer
support is no alternative: it is limited, offers few drivers, and DSM 7
itself warns that it will be discontinued in the next major system update.
So I investigated why the
toggle was ignored, found the cause in how CUPS passes that choice on to the
printer's driver, and put the fix together with everything else in this
project.

It is meant for people without much technical background. The only thing
you need is to be able to paste a few commands into an SSH session: the
installer finds the printer, suggests a driver, asks a few questions and
checks that the iPhone and Mac will see it.

If you have an older printer in the same situation, I hope this helps you
keep it in use.

## The black & white fix

The main thing this project adds is a **black & white toggle that works** on
iOS and macOS. With Foomatic/Ghostscript drivers, stock CUPS shows the
toggle in the print dialog but ignores it, and every page prints in color.
The installer corrects the driver so black & white really comes out in black
and white, and color in color. The details are in the next section.

The CUPS maintainers' view is that the driver should use the standard PPD
keyword (`Gray`), so the report now lives at
[OpenPrinting/cups-filters#801](https://github.com/OpenPrinting/cups-filters/issues/801)
and the fix is proposed to Foomatic in
[OpenPrinting/foomatic-db#65](https://github.com/OpenPrinting/foomatic-db/pull/65).
Until a fixed foomatic-db reaches Debian, this project applies the
workaround itself.

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
  drivers, `foomatic-db` (the Ghostscript drivers, such as `pxlcolor`,
  `pxlmono` and `ljet4`) and HP's `hpcups` drivers for most HP printers.
  Other families need one extra Debian package in the `apt-get install` line
  of the `Dockerfile`, then a rebuild: `printer-driver-brlaser` for many
  Brother lasers,
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
- The printer on the network with a **fixed IP address**. Reserve it in your
  router's DHCP settings before installing: if the printer gets another
  address later, printing stops. The IP and the MAC address are on the
  printer's network configuration page, which most printers can print from
  their control panel.
- DSM's own printer server turned off (port 631 must be free).

## Installation

On the NAS, over SSH:

```bash
cd ~ && curl -L https://github.com/rogercrocha/synology-cups-airprint/archive/refs/heads/main.tar.gz | tar xz \
  && mv synology-cups-airprint-main synology-cups-airprint
cd ~/synology-cups-airprint && sudo bash deploy.sh
```

DSM has no `git` unless you install the Git Server package, which is why the
download uses `curl`.

The first run asks a few questions, with a sensible default for each, so
you can usually just press Enter:

```
==> looking for printers on the network (about 20 seconds)
  1) Brother MFC-9460CDN                      192.168.1.50
  m) type the IP address
Printer [1]:

==> choosing a driver for Brother MFC-9460CDN
  1) Generic PCL 6/PCL XL Printer Foomatic/pxlcolor  (color printers)
  2) Generic PCL 6/PCL XL Printer Foomatic/pxlmono  (black & white printers)
  3) Generic PostScript Printer
  s) search the driver list
Driver [1]:

Name shown on iPhone and Mac [Brother MFC-9460CDN]:
Paper size (A4 or Letter) [A4]:
Location (optional):
Password for the web interface:
```

Printers are found by SNMP. If yours does not show up (SNMP is off on some
printers), choose `m` and type its IP address. The driver list shows drivers
made for that exact model first, then generic ones for the printer
languages it reports; `s` searches the whole list.

The script then builds and starts the container and checks what the iPhone
will see. Each step takes one line on screen, with the last few lines of the
running command underneath while it works; the full output goes to
`deploy.log` next to the script. On the iPhone or Mac, choose the printer whose name ends in
**"@ <your NAS name>"**. If the printer also announces itself, the entry
without the suffix is the printer, not this server.

Running `sudo bash deploy.sh` again rebuilds and restarts, keeping the
queue. To change the printer or any answer:

```bash
sudo bash deploy.sh --reconfigure
```

## Settings

The answers are saved in `/volume1/docker/synology-cups-airprint/.env`
(mode 600), together with the password for the CUPS web interface at
`http://<NAS-IP>:631` (user `print`). The wizard asks for that password; press
Enter to have one generated and shown at the end. You can also write that file yourself
from `.env.example`, for example to install without questions.

| Variable | Example | Meaning |
|---|---|---|
| `PRINTER_URI` | `socket://192.168.1.50:9100` | How CUPS reaches the printer |
| `PRINTER_PPD` | `foomatic:Generic-PCL_6_PCL_XL_Printer-pxlcolor.ppd` | Driver, from `lpinfo -m` |
| `QUEUE_NAME` | `Brother_MFC-9460CDN` | Queue name, no spaces |
| `QUEUE_DESC` | `Brother MFC-9460CDN` | Name shown on the devices |
| `PRINTER_LOCATION` | `Home` | Location text |
| `PAGE_SIZE` | `A4` | Default paper size |
| `COLOR_DEFAULT` | `color` | Default for jobs that do not say (macOS opens the dialog with it) |
| `CUPS_USER` / `CUPS_PASSWORD` | `print` | Login for the web interface |

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
