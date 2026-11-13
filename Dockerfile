FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

# cups-filters (1.28.x in Debian trixie) already ships foomatic-rip.
# Do NOT install foomatic-filters: it conflicts with cups-filters.
RUN apt-get update && apt-get install -y --no-install-recommends \
      cups \
      cups-filters \
      cups-ipp-utils \
      foomatic-db \
      foomatic-db-engine \
      ghostscript \
      avahi-daemon \
      avahi-utils \
      dbus \
      procps \
 && rm -rf /var/lib/apt/lists/*

# Pristine copy of the default config, used to fill in files that are
# missing when /etc/cups comes from an empty volume on first boot.
RUN cp -a /etc/cups /etc/cups-default

COPY entrypoint.sh airprint-setup /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/airprint-setup

# The driver list takes CUPS about a minute to generate, so the setup
# wizard reads a copy made once, here, instead of starting CUPS each time.
RUN airprint-setup build-driver-list

EXPOSE 631

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
