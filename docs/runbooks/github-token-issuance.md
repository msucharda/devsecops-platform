# Obnova nejistého vydání installation tokenu

`tools/New-PlatformGitHubToken.ps1` nesmí zopakovat vydání tokenu po ztrátě odpovědi. Token mohl vzniknout, ale bez jeho hodnoty nelze zavolat přímou revokaci. Issuer i jeho volající skončí chybou; výsledek není ověřený cleanup.

## Pending stav

Issuer před každým `POST /app/installations/{installation_id}/access_tokens` atomicky uloží intent (záměr vydání). Soubor obsahuje pouze URL API serveru bez přihlašovacích údajů a query, App ID, installation IDs, ID intentu a čas UTC. Neobsahuje token, JWT ani privátní klíč. Adresář smí číst a měnit jen aktuální uživatel.

Výchozí cesta na Windows je `%LOCALAPPDATA%\devsecops-platform\token-issuance\<hash>\pending.json`. Na Linuxu nástroj použije `$XDG_STATE_HOME/devsecops-platform/token-issuance/<hash>/pending.json`; bez `XDG_STATE_HOME` použije uživatelský adresář `LocalApplicationData`, obvykle `~/.local/share`. Hash vychází z API hostu včetně portu a App ID. Změna klíče, checkoutu ani installation ID blokaci neobejde.

Nepovinný parametr `-IssuanceStatePath` určí vlastní cestu mimo checkout. Pro tutéž App a API host musí všichni volající používat stejnou cestu. Změnou cesty neobcházej nevyřešený intent.

Issuer drží exkluzivní souborový zámek po celý běh. Další issuer i resolver při obsazeném zámku skončí chybou. Existující adresář s širším přístupem ani cestu přes symlink nástroj neopravuje; odmítne je. Linux vyžaduje standardní příkazy `id` a GNU `stat`.

Předkové stavového adresáře nesmí dovolit jinému neprivilegovanému uživateli přejmenovat nebo nahradit komponentu cesty. Na Linuxu musí předky vlastnit aktuální uživatel nebo root; sdílený zapisovatelný předek musí mít sticky bit. Na Windows nástroj důvěřuje aktuálnímu uživateli, SYSTEM, Administrators a TrustedInstaller a odmítne práva ostatních účtů k nahrazení adresáře. Samotný privátní koncový adresář ani otevřený file lock přejmenování nadřazené složky nebrání.

Pending soubor zůstává až do úspěšné revokace všech známých validačních tokenů nebo do úspěšného předání známých tokenů do environment output. Při chybě revokace nebo pádu procesu zůstane. Prázdný, poškozený i nečitelný pending stav blokuje nový POST a `Verified = true`. Obyčejné opakování příkazu soubor nesmaže.

Každá revokace musí vrátit dokumentovaný HTTP 204. Jiný nebo nečitelný status není potvrzená revokace a pending soubor zůstane. Volba `-VerifyRevocation` navíc vyžaduje, aby GitHub následný požadavek s revokovaným tokenem odmítl HTTP 401.

## Ruční vyřešení

Nejdřív ukonči předchozí issuer a zjisti dispozici možného tokenu. Chybový výstup uvádí cestu pending souboru, installations, ID intentu a zaznamenaný čas UTC. Samotný čas intentu není časem potvrzeného vytvoření tokenu.

Po alespoň 70 minutách od posledního zapsaného intentu můžeš blokaci výslovně uzavřít:

```powershell
.\tools\Resolve-PlatformGitHubTokenIssuance.ps1 -IssuanceStatePath '<cesta z chyby>'
```

Jde o provozní dispozici: GitHub dokumentuje platnost tokenu jednu hodinu od vytvoření; dalších deset minut je rezerva. Příkaz nevolá GitHub API a neprokazuje revokaci ani přesný okamžik vytvoření. Pokud nemáš podklad pro expiraci, nepovažuj samotné uplynutí intervalu za důkaz.

Před uplynutím intervalu nebo při nečitelném čase musíš nezávisle potvrdit, že token vypršel nebo byl revokován jiným postupem. Teprve potom použij:

```powershell
.\tools\Resolve-PlatformGitHubTokenIssuance.ps1 -IssuanceStatePath '<cesta z chyby>' -ConfirmTokenExpiredOrRevoked
```

Switch je výslovné potvrzení operátora, nikoli požadavek na revokaci. Resolver vypíše `Disposition`, `Resolved = true` a `Verified = false`. Žádný token nevydá ani nerevokuje. Po odstranění blokace můžeš původní operaci spustit znovu.

Pending soubor nemaž ručně a neupravuj jeho čas. Chybnou identitu nebo nečitelný obsah vyřeš až po nezávislém ověření dispozice tokenu. Chyba přístupu není důvod ke změně App oprávnění.

## Efemérní runnery

Na efemérním runneru GitHub Actions pending soubor zanikne s jobem. Fail-closed tam zajišťuje selhání jobu, nikoli zachování souboru do dalšího jobu. Nový job nemá důkaz cleanupu předchozího jobu. Před jeho ručním opakováním musí operátor vypořádat možné tokeny předchozího běhu.

## Primární kontrakt

GitHub REST API `2026-03-10`:

- [Create an installation access token for an app](https://docs.github.com/en/enterprise-cloud@latest/rest/apps/apps?apiVersion=2026-03-10#create-an-installation-access-token-for-an-app): token expiruje jednu hodinu od vytvoření.
- [Revoke an installation access token](https://docs.github.com/en/enterprise-cloud@latest/rest/apps/installations?apiVersion=2026-03-10#revoke-an-installation-access-token): DELETE revokuje token použitý k autentizaci; installation ID jej nenahrazuje.
