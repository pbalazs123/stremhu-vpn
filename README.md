# StremHU VPN installer (PIA)

**[Magyar](#magyar) · [English](#english)**

---

## Magyar

Egy varázsló, ami a meglévő [StremHU Source](https://github.com/s4pp1/stremhu-source) telepítésedet PIA WireGuard VPN mögé teszi, bárhogyan is van beállítva. A torrentforgalom az alagúton megy, kill switch-csel és automatikus porttovábbítással. A köteteidhez nem nyúl, és egy paranccsal minden visszaállítható.

### Telepítés

Linux, Docker Compose 2.24 vagy újabb, PIA előfizetés és egy futó StremHU kell hozzá.

```bash
curl -fsSL https://raw.githubusercontent.com/pbalazs123/stremhu-vpn/main/install.sh -o install.sh
sudo bash install.sh
```

A telepítő megkeresi a StremHU-t, bekéri a PIA adataidat, és megmutatja, mit fog csinálni. Csak a jóváhagyásod után változtat. A végén leteszteli az eredményt, és bármilyen hiba esetén visszaállítja az eredeti állapotot.

```bash
sudo bash install.sh status      # állapot
sudo bash install.sh uninstall   # az eredeti beállítás visszaállítása
```

### Amit biztosan nem csinál

- Nem ír a StremHU köteteibe vagy mappáiba, és nem változtatja meg a fájlok tulajdonosát.
- Nem szerkeszti a compose fájljaidat.
- Nem nyúl a projekted többi szolgáltatásához.

A StremHU új fájljai az 1000-es felhasználóhoz tartoznak, vagy a saját felhasználódhoz, ha már beállítottál egyet. A StremHU torrent port beállítása a PIA portjára vált, és az eltávolítás visszaállítja.

### Korlátok

- Csak PIA-val és Linuxon működik.
- Portainer, Dockhand, Unraid és hasonlók esetén külön stack jön létre. Vedd ki a StremHU-t abból az eszközből, különben egy újratelepítés **VPN nélkül** indítja el.
- A webes porton a kliensek a szervered IP-címét látják. A VPN a torrentezést védi.
- A StremHU automatikus DDNS-e publikus kapcsolattal nem tudja frissíteni az IP-címet. Dinamikus IP-nél használj más frissítőt, például a routeredét.
- A StremHU belső felépítésére támaszkodik, így egy frissítés elronthatja.

### Tesztelés

Egy Debian 13 szerveren tesztelve, 2026. november 2-án: hivatalos és erősen egyedi compose, `docker run`, valódi párbeszédablakok, hibás jelszó, kényszerített hiba, megszakított telepítés, kill switch, eltávolítás.

**Nem tesztelve:** Portainer, Dockhand, Unraid, más disztribúciók, a csomag telepítése, a sima szöveges kérdések, régi Compose, valódi internetes kliens és router porttovábbítás, valódi DDNS, valódi letöltés és lejátszás, szerver újraindítása vagy áramszünet telepítés közben.

Nem hivatalos kiegészítő, nem a StremHU része. A VPN-t a [thrnz/docker-wireguard-pia](https://github.com/thrnz/docker-wireguard-pia) adja. Az API-n át történő port-beállítás ötlete az [adrianmihalko/stremhu-pia-helper](https://github.com/adrianmihalko/stremhu-pia-helper) projektből származik.

---

## English

A guided installer that puts your existing [StremHU Source](https://github.com/s4pp1/stremhu-source) behind a PIA WireGuard VPN, however it's set up. Torrent traffic goes through the tunnel with a kill switch and automatic port forwarding. Your volumes stay as they are, and one command puts everything back.

### Install

You need Linux, Docker Compose 2.24 or newer, a PIA subscription and a running StremHU.

```bash
curl -fsSL https://raw.githubusercontent.com/pbalazs123/stremhu-vpn/main/install.sh -o install.sh
sudo bash install.sh
```

The installer finds StremHU, asks for your PIA details and shows what it will do. It changes nothing until you confirm. It then tests the result, and puts the original back if anything fails.

```bash
sudo bash install.sh status      # current state
sudo bash install.sh uninstall   # restore your original setup
```

### What it never does

- It doesn't write to StremHU's volumes or folders, or change who owns the files.
- It doesn't edit your compose files.
- It doesn't touch other services in your project.

New files StremHU creates belong to user 1000, or to your own user if you already set one. StremHU's torrent port setting moves to PIA's port, and uninstall puts it back.

### Limits

- It only works with PIA, on Linux.
- With Portainer, Dockhand, Unraid and similar tools, it creates a separate stack. Remove StremHU from that tool, or a redeploy starts it **without the VPN**.
- Clients on the web port see your server's IP. The VPN protects torrenting.
- StremHU's automatic DDNS on a public connection can't update your IP. With a dynamic IP, use another updater, such as your router's.
- It relies on StremHU's internals, so an update could break it.

### Testing

Tested on one Debian 13 server on 2 November 2026: official and heavily customised compose files, `docker run`, the real dialogs, a wrong password, a forced failure, a killed install, the kill switch and uninstall.

**Not tested:** Portainer, Dockhand, Unraid, other distributions, installing the dialog package, plain-text prompts, old Compose versions, a real internet client and router port forward, real DDNS, real downloads and playback, a server reboot or power cut during the install.

This is an unofficial add-on, not part of StremHU. The VPN comes from [thrnz/docker-wireguard-pia](https://github.com/thrnz/docker-wireguard-pia). The idea of setting the port through the API comes from [adrianmihalko/stremhu-pia-helper](https://github.com/adrianmihalko/stremhu-pia-helper).
