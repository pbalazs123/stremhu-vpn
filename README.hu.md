<p align="center">
  <img src="assets/logo-256.png" alt="StremHU VPN logó" width="110"/>
</p>

<h1 align="center">StremHU VPN</h1>

<p align="center">
  <b>A meglévő StremHU-d PIA VPN mögé téve</b><br/>
  Egy varázsló, ami bárhogyan beállított StremHU-val működik. A köteteidhez nem nyúl, és egy paranccsal minden
  visszaállítható.
</p>

<p align="center"><a href="README.md">English</a></p>

---

## ✨ Mit tud

| | |
|---|---|
| **Illeszkedik a beállításodhoz** | A fájlneveket, a szolgáltatást, a portot, a felhasználót és a hálózatokat a Dockerből olvassa ki, így egyedi Compose fájllal és `docker run`-nal is működik |
| **Torrent az alagúton át** | PIA WireGuard, kill switch-csel és automatikus porttovábbítással |
| **A webes elérés nem változik** | Ugyanaz a port ugyanazon a címen, publikusan vagy NAT mögött is |
| **A köteteid érintetlenek maradnak** | Nem ír beléjük, nem mozgatja őket, és nem változtatja meg a fájlok tulajdonosát |
| **Vezetett telepítés** | Párbeszédablakok, mint a Debian telepítőjében. Ha hiányzik a szükséges csomag, felteszi |
| **Hiba esetén visszaáll** | Leteszteli az eredményt, szándékosan el is vágja az alagutat, és ha valami nem sikerül, visszaállítja az eredetit |
| **Eltávolítható** | Egy parancs visszaállítja az eredeti beállításodat |

## 📦 Telepítés

Ami kell hozzá:

- Már futó StremHU Source, Linuxon
- PIA előfizetés
- Docker, Compose 2.24 vagy újabb
- Root vagy `sudo`

Futtasd ezt a StremHU-t futtató gépen, bármelyik mappából:

```bash
curl -fsSL https://raw.githubusercontent.com/pbalazs123/stremhu-vpn/main/install.sh -o install.sh
sudo bash install.sh
```

A telepítő megkeresi a StremHU-t, bekéri a PIA adataidat és a helyszínt, majd összefoglalót mutat. A jóváhagyás után
körülbelül 2 percig tart.

```bash
sudo bash install.sh status      # állapot
sudo bash install.sh uninstall   # az eredeti beállítás visszaállítása
```

## 🔒 A köteteid

A telepítő semmit nem ír, nem mozgat, nem töröl a StremHU köteteiben vagy mappáiban, és a tulajdonost sem változtatja meg.
Csak a saját két kötetét törli: `stremhu-vpn-pia` és `stremhu-vpn-pia-shared`.

- **Új fájlok:** amit a StremHU a VPN mögött hoz létre, az az 1000-es felhasználóé, vagy a sajátodé, ha már beállítottál egyet.
- **Torrent port:** a StremHU beállítása a PIA portjára vált, és az eltávolítás visszaállítja a régi értéket.

## 🚧 Korlátok

- Csak PIA-val és Linuxon működik, a Docker Swarm nem támogatott.
- Portainer, Dockhand, Unraid és hasonlók esetén vedd ki a StremHU-t abból az eszközből, különben egy újratelepítés **VPN nélkül** indítja el.
- A webes porton a kliensek a szervered IP-címét látják. A VPN a torrentezést védi, a webes elérést nem.
- A StremHU automatikus DDNS-e a VPN mögül nem tudja frissíteni az IP-címet. Dinamikus IP-nél használj más frissítőt, például a routeredét.
- A StremHU belső felépítésére támaszkodik, így egy StremHU-frissítés elronthatja.

## 🧪 Tesztelés

Egy Debian 13 szerveren tesztelve, 2026. november 2-án: hivatalos és erősen egyedi Compose fájlok, `docker run`, valódi
párbeszédablakok, hibás jelszó, kényszerített hiba, megszakított telepítés, kill switch, eltávolítás.

**Nem tesztelve:** Portainer, Dockhand és Unraid; más disztribúciók; a csomag telepítése; a sima szöveges kérdések; régi
Compose; valódi internetes kliens és router porttovábbítás; valódi DDNS; valódi letöltés és lejátszás; újraindítás vagy
áramszünet telepítés közben.

## 🐛 Hibaelhárítás

A hibaüzenetek angolul jelennek meg.

**"PIA rejected that username or password":** a PIA-fiókod `p` betűvel kezdődő felhasználónevét használd. Nem változott semmi.

**"No StremHU Source container was found":** először indítsd el a StremHU-t. Saját Docker image-nél add hozzá: `--container NÉV`.

**"Docker Compose 2.24 or newer is needed":** frissítsd a Compose bővítményt, majd futtasd újra. Nem változott semmi.

**"The VPN didn't connect within 3 minutes":** a telepítő visszaállt. Próbálj másik helyszínt, és ellenőrizd, hogy a gép engedi-e a WireGuardot.

**Figyelmeztetés a torrent portról:** hozd létre a StremHU admin felhasználóját. Utána 30 másodpercen belül beáll a port.

**A `status` WARNING-ot ír a Public IP sorban:** a StremHU nincs a VPN mögött. Általában az a gond, hogy valami újraindította a régi beállítást.

**Bármi más:** a teljes napló itt van: `/var/log/stremhu-vpn-install.log`.

## 🙏 Köszönet

- [thrnz/docker-wireguard-pia](https://github.com/thrnz/docker-wireguard-pia): a VPN konténer
- [adrianmihalko/stremhu-pia-helper](https://github.com/adrianmihalko/stremhu-pia-helper): az ötlet, hogy a port a StremHU API-ján át állítható

Nem hivatalos kiegészítő, nem kapcsolódik a [StremHU Source](https://github.com/s4pp1/stremhu-source) projekthez vagy a Private Internet Accesshez.

## 📄 Licenc

[MIT](LICENSE)

<p align="center"><a href="https://github.com/pbalazs123/stremhu-vpn/issues">Hiba jelentése</a></p>
