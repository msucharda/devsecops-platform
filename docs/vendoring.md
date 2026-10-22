# Workflow vendoringu

Jediný reusable workflow (opakovaně použitelný workflow) `templates/instance/.github/workflows/vendor.yml` připraví akci nebo Release (release) podle tagu a otevře PR v cíli. Zdrojový kód nikdy nespouští. Workflow nezakládá organizace, repozitáře ani Apps; ty musí existovat před živým importem.

## Vstupy a katalog

Bootstrap umístí workflow do `.github/workflows/vendor.yml` v Instance repository (repozitáři instance). Schválené nástroje leží v `platform/tools/`. Volající workflow musí běžet z chráněné `main` při `workflow_dispatch` nebo `push`. PR event ani větev mimo `main` import nespustí. Volající workflow, reusable workflow, katalog i změny App oprávnění musí projít review.

| Vstup | Význam |
|---|---|
| `source-repository` | Zdroj ve formátu `owner/repo`. |
| `source-tag` | Přesný tag, nikoli větev. Nástroj rozbalí annotated tag na commit SHA. |
| `source-api-url` | HTTPS API origin `https://api.github.com` nebo `https://api.<enterprise>.ghe.com`. Výchozí hodnota míří na github.com. |
| `source-asset` | Název ZIP assetu z release tohoto tagu. Pro import release platformy musí volající určit tento asset; automatický zdrojový ZIP není náhrada attestovaného release. Pro akci bez assetu nástroj stáhne zdrojový ZIP z rozlišeného commit SHA. |
| `private-source` | `true` vydá samostatný read-only installation token pro předem deklarovaný zdroj. Výchozí `false` čte zdroj bez autentizace. |
| `target-repository` | Existující cíl `owner/repo` na hostu instance, s větví `main`. |
| `kind` | `action` nebo `release`. |
| `actions-organization` | Actions organization (organizace akcí), do které musí patřit všechny katalogové kopie. |

Workflow vrátí výstup `pull-request`. Prázdná hodnota znamená, že import nenašel diff; není to cloudový plan.

Katalog `vendoring/actions.json` v repozitáři instance má verzi `1` a mapu `actions`. Prázdnou šablonu naplní platformní tým po schválení importů. Klíč určuje upstream repozitář; `repository` určuje kopii `{owner}-{repo}`, `tag` tag upstreamu a `sha` skutečný merge commit kopie:

```json
{
  "version": 1,
  "actions": {
    "actions/checkout": {
      "repository": "example-actions/actions-checkout",
      "tag": "v4.2.2",
      "sha": "1111111111111111111111111111111111111111"
    }
  }
}
```

SHA v příkladu je pouze placeholder. Platformní tým musí přes API cílového repozitáře ověřit skutečný commit a jeho schválení security týmem. Offline validátor kontroluje formát a cílovou organizaci, nikoli existenci nebo schválení commitu. Katalog vybírá jednu schválenou kopii pro každý upstream repozitář; upstream reference sama nevybírá jinou verzi kopie.

Modul [actions-catalog](../modules/actions-catalog/README.md#katalog-vendoringu) čte katalog jako jediný zdroj schválených importů. Pro každou položku vytvoří ve vendorované kopii tag `tag` na commitu `sha` a pole `tag` vyžaduje. Offline validátor importu pole `tag` nekontroluje.

## Příprava a attestace

`Get-VendoringSource.ps1` nejprve rozliší tag na immutable commit (neměnný commit). ZIP asset vybere z release stejného tagu. Asset musí obsahovat jediný kořenový adresář. Nástroj odmítne traversal, `.git`, duplicitní cesty, symbolické odkazy a rozbalený obsah nad 512 MiB.

Nástroj spočítá SHA256 stažených bajtů a dotáže API attestací pro tento digest. Úspěšná odpověď s prázdnou kolekcí znamená `not-present`. Veřejné API github.com vrací pro neregistrovaný digest také HTTP 404; nástroj tento stav přijme jen po samostatném potvrzení identity a veřejné viditelnosti zdrojového repozitáře a vypíše varování o neověřené provenance. HTTP 404 u privátního zdroje nebo na GHE.com, jiná HTTP chyba, chybějící oprávnění ani nepodporované API nejsou důkazem absence a import zastaví. Nejednoznačný stav vyžaduje deklarovaný ruční import.

Při existující attestaci nástroj stáhne bundle z `bundle_url` každé attestace bez autentizačních hlaviček. Přijme jen HTTPS URL bez přihlašovacích údajů a nejvýše 16 MiB staženého i dekódovaného obsahu. Bundle je komprimovaný formátem Snappy; nástroj ho dekóduje sám. Pak `gh attestation verify <zip> --bundle <soubor>` ověří podpis, digest artefaktu, zdrojový repozitář, `refs/tags/<tag>`, rozlišený source commit a hosted runner (`--deny-self-hosted-runners`). Import pokračuje, když projde aspoň jeden bundle. Neplatná nebo neověřitelná attestace import zastaví ještě před rozbalením. Nástroj zaznamená `verified` až po úspěšném ověření.

Ověření z lokálního bundle nepotřebuje token, protože `gh` nevolá API attestací. Rozhodnutí: nástroj vždy používá `--bundle`. Probe na GitHub-hosted runneru referenční instance GHE.com (gh 2.102.0) ověřil attestaci z github.com i bez `--bundle` a bez tokenu, ale starší verze `gh` bez tokenu selžou. `--bundle` funguje v obou případech. Stejný probe potvrdil síťovou dostupnost github.com, API attestací, úložiště bundle a Sigstore trust root z runneru GHE.com a odmítnutí změněného artefaktu.

Import release (`kind: release`) vyžaduje stav `verified` a signer workflow (podepisující workflow) `<zdroj>/.github/workflows/release.yml`. Stav `not-present` import release zastaví ještě před rozbalením. Signer workflow běží z otagovaného commitu, a proto jeho vlastní kontrola předka `main` nestačí. Import release proto nezávisle ověří přes `GET /repos/{owner}/{repo}/compare/main...{commit}`, že commit tagu je na `main`: `status` musí být `behind` nebo `identical` a `merge_base_commit.sha` musí být tento commit. Jinak se import zastaví před stažením assetu. Attestace platí pro stažený artefakt, nikoli pro všechny soubory release. Automatický zdrojový ZIP akce může mít stav `not-present`; tento stav nikdy neznamená ověřenou provenance (provenienci).

Sdílená IP adresa hosted runneru může vyčerpat limit neautentizovaných požadavků; probe po jednom volání viděl `X-RateLimit-Remaining: 55`. Nástroj při HTTP 403 nebo 429 s vyčerpaným limitem čeká podle `retry-after` nebo `x-ratelimit-reset`, u secondary rate limit bez hlaviček 60, 120 a 240 s. Zkusí nejvýše 3 opakování a čeká nejvýše 300 s. Pak skončí chybou `rate limit for the source is exhausted`.

`ConvertTo-VendoredSource.ps1` přepíše skutečné YAML hodnoty `uses` v composite akcích, včetně vnořených `action.yml` a `action.yaml`. Pro release přepíše kroky a reusable job references v `templates/instance/.github/workflows/`. Nepřepisuje text ve skriptech, komentáře, testovací fixtures ani zdrojové CI, které pod `platform/` neběží jako workflow instance. Subpath akce zachová a upstream ref nahradí katalogovým SHA. Chybějící katalogová akce způsobí chybu s jejím názvem ještě před vytvořením výstupu.

Lokální `./` odkazy a `docker://` references zůstávají beze změny; nejsou to vzdálené GitHub akce. Docker images musí security tým posoudit zvlášť. Dynamické `uses` a YAML anchors nebo aliases nástroj odmítne místo neúplného přepisu. Import zachová binární soubory. Příprava na Linuxu zapíše executable bits (příznaky spustitelnosti) do manifestu mimo připravený strom; publikace je po artifact přenosu obnoví v souborech i Git indexu. Manifest musí obsahovat právě všechny připravené soubory a boolean příznaky; nesmí obsahovat příkazy ani libovolné filesystem paths (cesty souborového systému). Lokální příprava na Windows bez původních Unix modes (unixových režimů) spustitelnost nezjistí; člověk ji musí doložit z původního archivu nebo provést přípravu na Linuxu.

## Diff, oprávnění a hranice cloudového planu

Příprava a publikace běží v oddělených jobech a předávají jen připravená data, receipt (záznam původu) a mode manifest (manifest příznaků spustitelnosti) přes artifact stejného běhu. Publikace spouští pouze nástroje z důvěryhodné `main`, nikoli skripty kandidáta.

| Environment | App a scope (rozsah) |
|---|---|
| `vendoring-source` | Jen pro privátní zdroj: samostatná enterprise-owned App s přesně `contents: read` a `attestations: read`. Installation token pokrývá jen deklarovaný zdroj. Veřejný import žádný zdrojový klíč nepoužije. |
| `vendoring-action-import` | Samostatná enterprise-owned App s přesně `contents: write` a `pull_requests: write`, instalovaná jen v organizaci akcí. Installation token pokrývá jen cílový repozitář akce. |
| `vendoring-release-import` | Jiná enterprise-owned App se stejnými oprávněními, instalovaná jen v organizaci platformy. Installation token pokrývá jen repozitář instance. |

Všechny tři environmenty musí povolit jen chráněnou `main`. Oba import environmenty musí vyžadovat schválení platformním týmem. Nesmějí obsahovat `workflows: write`, organization administration, Azure nebo Microsoft Graph credentials. Oddělené writer vazby umožňují import do obou organizací, aniž by App získala instalaci v jiné organizaci. Privátní klíče patří jen do příslušných environment secrets, ne do repository nebo organization secrets dostupných běžným jobům. Správu, rotaci po nejvýše 90 dnech a odstranění Apps určuje ADR 0016. Workflow neprovisionuje environmenty ani identity; platformní tým je připraví jako řízený krok.

Každý environment s App deklaruje `PLATFORM_APP_ID`, `PLATFORM_APP_INSTALLATION_ID`, `PLATFORM_APP_ENTERPRISE` a secret `PLATFORM_APP_PRIVATE_KEY` podle stávajícího tokenového interface. `vendoring-source` navíc deklaruje `SOURCE_REPOSITORY` a `SOURCE_API_URL`; privátní vstupy se s nimi musí shodovat před použitím klíče. `New-PlatformGitHubToken.ps1 -VendoringRepository owner/repo` kontroluje skutečného enterprise vlastníka, přesná oprávnění App a instalací, cílovou organizaci a active selected installation. Token vydá s explicitním omezením na jméno cílového repozitáře a zkontroluje jeho skutečný rozsah. `-ReadOnlySource` zvolí oddělený zdrojový kontrakt. Širší oprávnění způsobí chybu.

`Publish-VendoringPullRequest.ps1` vyžaduje čistý checkout cílové `main` a ověřený installation token. Akce vlastní obsah kořene cílového repozitáře kromě `.github/`; upstream `.github/` se neimportuje, aby nepřepsal governance ani nespustil cizí workflow. Release vlastní jen `platform/`. Nástroj odstraní staré tracked soubory uvnitř příslušné hranice a přidá nové; zachová konfiguraci instance i živé workflow. Do `.vendoring.json`, pro release do `platform/.vendoring.json`, zapíše tag, source commit, digest a stav attestace. Licence a ostatní soubory zdroje zůstávají součástí diffu.

Větev importu má stabilní identitu: `vendor/<kind>/<zdroj>-<tag>-<hash>`. Hash je prvních 16 znaků SHA256 z druhu importu, zdroje (malými písmeny) a tagu. Číslo ani pokus běhu workflow identitu neovlivní. Opakovaný běh proto obnoví přerušený import takto:

- Vzdálená větev se stejným stromem a rodičem zůstane beze změny; nástroj nepushuje.
- Vzdálenou větev s jiným obsahem nástroj přepíše přes `--force-with-lease`, ale jen pokud obsahuje jediný commit vendoringu nad historií `main`. Commit jiného autora, merge commit nebo cizí historie import zastaví s chybou; větev musí zkontrolovat člověk.
- Otevřený PR z této větve do `main` nástroj použije znovu (`GET /repos/{owner}/{repo}/pulls` s filtrem `head` a `state=all`). Rozdílný název nebo popis aktualizuje (`PATCH /repos/{owner}/{repo}/pulls/{pull_number}`). Víc otevřených PR nebo PR do jiné větve než `main` import zastaví s chybou.
- PR větve, který neotevřela App (autor není typu `Bot` s loginem `*[bot]`), import zastaví s chybou ještě před push. Push by PR synchronizoval a lidský autor PR může deployment authorization (autorizace nasazení) propustit k cloudovému planu.
- Uzavřený PR App nástroj ignoruje a otevře nový PR ze stejné větve. Nečitelná položka seznamu PR nebo jiný stav než `open` a `closed` import zastaví s chybou.
- Mělký checkout cílové `main` nástroj před kontrolou historie doplní (`fetch --unshallow`), pokud stará větev importu vychází z dřívějšího commitu `main`.

PR otevře installation token, nikoli `GITHUB_TOKEN`. GITHUB_TOKEN workflow má pouze `contents: read` pro checkout důvěryhodných nástrojů. Tokeny se po použití odvolají i při chybě. Chyba push nebo vytvoření PR se nesmí vykázat jako úspěšný import. Nástroj nevynucuje merge ani nevytváří upstream tag v cíli; tagování schválené kopie řeší #15 po review.

PR body a summary uvádějí **Cloud PR plan: NOT PERFORMED**. Stávající deployment authorization odmítne App autora před předáním cloudových credentials. PR z větve `vendor/*` odmítne bez ohledu na autora: App větev importu při obnově force-pushuje, takže PR člověka z této větve může obsahovat neschválený obsah. Po review a merge do chráněné `main` proběhne nový plan před schváleným apply. Úspěšná příprava, validace YAML, vytvoření PR ani ruční krok nejsou cloudový plan.

### Ruční povýšení živých workflow v #16

Uživatel schválil zachování omezených App oprávnění: automatický import uloží přepsané šablony jen pod `platform/`. Zápis do živých `.github/workflows` by vyžadoval další `workflows: write`; App ho nesmí získat kvůli vendoringu.

Po review release platformní tým připraví samostatný PR s povýšením schválených šablon do `.github/workflows`. Security tým schválí diff a platformní tým zajistí, že workflow používají katalogové SHA a zachovávají authorization gates (autorizační podmínky), environmenty a pořadí plan → approval → apply. Tento ruční krok z #16 se nesmí vykázat jako automaticky ověřený běh. Rozhodnutí upřesňuje acceptance criteria (akceptační kritéria) v [#16](https://github.com/msucharda/devsecops-platform/issues/16#issuecomment-6148995640).

## Nedostupný privátní zdroj: Manual step (ruční krok)

Pokud enterprise-owned App nemůže zdroj číst, automatický import skončí konkrétní chybou. Workflow nesmí použít osobní PAT, OAuth token ani širší App scope. Platformní tým provede deklarovaný ruční import do zpřístupnění zdroje:

1. Oprávněný člověk stáhne přesný tag nebo release asset mimo workflow. Zapíše zdroj, tag, rozlišený commit, SHA256 a původ získaných bajtů. Credential nepřenese do repozitáře ani workflow.
2. Pokud zdroj poskytuje attestaci, člověk ji ověří pro stejné bajty, zdroj a tag. Neplatná attestace import zastaví. Chybějící nebo nedostupné ověření výslovně zaznamená; nesmí použít stav `verified`.
3. Člověk bezpečně rozbalí zdroj a spustí `ConvertTo-VendoredSource.ps1` nad lokálními daty a schváleným katalogem. Výsledek vloží do PR v hranici daného importu. Security tým schválí diff včetně licencí a přiznaných omezení.

Ruční PR musí uvést **Manual import; source access was not verified by the workflow; cloud plan NOT PERFORMED**. Stav `manual-not-verified` v receipt přiznává neověřený původ; nezaměňuje ho za absenci attestace ani úspěšné ověření. Po review a merge do chráněné `main` následuje plan před schváleným apply. Drift ani opakovatelnost ručně získaného zdroje nejsou automaticky ověřené.

## Release platformy a import do instance

Zdrojový repozitář vydává release workflow `.github/workflows/release.yml`. Spouští ho push tagu `vMAJOR.MINOR.PATCH` nebo `vMAJOR.MINOR.PATCH-rc.N`. Workflow:

1. Odmítne jiný formát tagu, tag přesunutý po startu běhu a commit, který není předkem `main`.
2. Sestaví `platform-<tag>.zip` příkazem `git archive` s jediným kořenovým adresářem `devsecops-platform-<verze>/`.
3. Vytvoří build provenance attestaci akcí `actions/attest-build-provenance`.
4. Spustí `tools/Publish-PlatformRelease.ps1`.

`Publish-PlatformRelease.ps1` znovu ověří, že tag ukazuje na sestavený commit; annotated tag rozbalí. Release vytvoří jako draft, nahraje asset a zkontroluje, že GitHub vrátil `state: uploaded` a `digest` lokálního souboru. Teprve potom release publikuje. Release candidate je prerelease s `make_latest: false`. Opakovaný běh najde draft přes výpis release a dokončí ho: smaže neúplné, zastaralé a cizí assety. Publikovaný release s jiným obsahem nástroj nikdy nemění a skončí chybou; oprava vyžaduje nový tag. Každý zapisující krok pokrývá harness přerušení.

Instance repository importuje release workflowem `import-release.yml` (`workflow_dispatch`, vstup `tag`). Job `resolve` spustí `Resolve-PlatformReleaseImport.ps1`: ověří formát tagu, odvodí asset `platform-<tag>.zip` a organizaci akcí z `instance.yaml` a názvu organizace platformy. Zdroj určuje proměnná `PLATFORM_SOURCE_REPOSITORY`, výchozí hodnota je `msucharda/devsecops-platform`. Job `import` volá `vendor.yml` s `kind: release`, veřejným zdrojem a `source-api-url: https://api.github.com`. Výsledkem je PR pod `platform/`; živé workflow povyšuje ruční krok výše.

## Offline a živé ověření

Pester testy volají veřejné skripty. Fixtures ověřují přepis composite akcí, zachování lokálních odkazů a script textu, missing catalog error (chybu chybějící katalogové akce), release hranici, tag resolution (rozlišení tagu), attestation failure (selhání attestace), bezpečnost ZIP a omezení installation tokenu. PR test používá skutečný lokální Git a nahrazuje jen push a HTTP API.

```powershell
Invoke-Pester -Path .\tools\tests\Vendoring*.Tests.ps1, .\tools\tests\PlatformRelease*.Tests.ps1 -Output Detailed
.\tools\Invoke-Tests.ps1 -Tag Interruption
.\tools\Test-PowerShell.ps1
```

Živé ověření přesunuté z #14 je součástí akceptace #16. Před uzavřením #16 musí platformní tým vydat první release candidate, ověřit jeho attestaci z runneru instance a importovat ho do Reference instance. Dále musí platformní tým na Reference instance (referenční instanci) doložit cílový repozitář, dostupnost App installation a API, omezená oprávnění, PR s diffem, skutečné kryptografické ověření dostupné attestace a odmítnutí neplatné attestace. Musí doložit, že App PR nedostal cloudové credentials a po review a merge proběhl plan před schváleným apply. Dosavadní offline fixtures tento živý běh nenahrazují. Výsledek nesmí zveřejnit identifikátory ani credentials instance.

## Zdroje

- [ADR 0002](adr/0002-customers-vendor-releases.md), [ADR 0012](adr/0012-public-source-repository.md) a [ADR 0016](adr/0016-github-app-installation-tokens-for-instance-workflows.md).
- [REST API attestací](https://docs.github.com/en/enterprise-cloud@latest/rest/repos/attestations#list-attestations), [GitHub CLI attestation verify](https://cli.github.com/manual/gh_attestation_verify) a [installation token scope](https://docs.github.com/en/rest/apps/apps#create-an-installation-access-token-for-an-app).
- [REST API releases](https://docs.github.com/en/enterprise-cloud@latest/rest/releases/releases), [release assets](https://docs.github.com/en/enterprise-cloud@latest/rest/releases/assets) a [git refs](https://docs.github.com/en/enterprise-cloud@latest/rest/git/refs#get-a-reference), verze API `2026-03-10`.
- [Rate limits pro REST API](https://docs.github.com/en/enterprise-cloud@latest/rest/using-the-rest-api/rate-limits-for-the-rest-api#exceeding-the-rate-limit) a [artifact attestations](https://docs.github.com/en/enterprise-cloud@latest/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations).
