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

Veřejnou akci importuje volající `import-action.yml` (`workflow_dispatch`, vstupy `repository` a `tag`). `Resolve-ActionImport.ps1` normalizuje upstream `owner/repo` na malá písmena a odvodí cíl `<organizace-akcí>/<owner>-<repo>` z identity instance a organizace platformy. Přijme jen upstream z `modules.actions-catalog.parameters.catalog`; bez explicitního seznamu použije výchozí katalog modulu. Chybějící modul, neplatný katalog nebo kolizi cílových jmen odmítne před zápisem výstupů. Volající nemůže zadat jiný cíl ani rozšířit scope. Cílový repozitář musí předem vytvořit modul `actions-catalog`. Import používá stejné main/event kontroly, oddělenou přípravu a publikaci i ověření tokenu jako import release. Po main/event kontrole ověří samostatný job přítomnost writer credentials ještě před prvním source nebo writer tokenem.

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

## Aktualizace akce v instanci

Release platformy určuje upstream piny šablon. Katalog instance určuje SHA schválených vendorovaných kopií. Tato SHA se liší: upstream SHA označuje zdroj akce, katalogové SHA označuje commit importu v organizaci akcí.

Přepis `uses:` nesmí změnit chování workflow (pravidlo O11). Před importem release musí platformní tým pro každý jeho pin ověřit, že katalogová kopie pochází z tagu se stejným upstream commit SHA. Samotná shoda názvu akce nestačí. Import release používá právě aktuální katalog; nevybírá verzi podle upstream ref v `uses:`.

1. Autor platformy zvýší piny, ověří změny runtime, vstupů a výstupů a vydá release s tabulkou upstream → tag → SHA. Platformní tým zkontroluje tuto tabulku a diff šablon.
2. **Ještě před importem nového release** spustí platformní tým stávající `import-action.yml` pro každou změněnou akci s přesným upstream repozitářem a novým tagem z tabulky. Tag musí ukazovat na SHA pinu. Cílem zůstává stejný repozitář `{owner}-{repo}`; nový tag vytváří jinou importní větev a nový PR.
3. Security tým zkontroluje diff, licenci a `.vendoring.json`: `source`, `tag` a upstream `commit` musí odpovídat schválené verzi. Po schválení platformní tým sloučí PR do `main` vendorované kopie a přes API zjistí skutečné SHA tohoto commitu. Upstream SHA nesmí zapsat místo SHA kopie.
4. V samostatném PR repozitáře instance změní platformní tým `tag` a `sha` příslušné položky `vendoring/actions.json`. `repository` zůstává stejné. Po review a merge provede plan → approval → apply modulu `actions-catalog`; modul vytvoří nový tag na schváleném commitu kopie.
5. Platformní tým spustí `import-release.yml` pro nový release platformy, už s aktualizovaným katalogem. Ověří, že přepsané šablony používají schválené SHA kopií a že jejich receipt dokládá upstream SHA pinů. Po review a merge povýší šablony do živých workflow samostatným PR podle [postupu povýšení](#ruční-povýšení-živých-workflow-v-16).
6. Platformní tým spustí workflow s novým pinem a ověří jeho výsledek. Zelené CI platformy ani úspěšný import nenahrazují toto živé ověření.

Starý tag zůstává na původním commitu. Import nového obsahu mění `main`, nikoli starý tag; změna katalogu ani destroy modulu starý tag nemaže. Starý tag a jeho commit musí zůstat dostupné, dokud je používá některý pin v instanci nebo ve workloadech. Modul tagy automaticky nečistí a existující tag nikdy nepřesune.

Opakování stejného importu navazuje na stejný PR. Import jiného tagu po merge předchozího importu založí nový PR nad aktuální `main` a zachová `.github/` i původní tagy. Offline regresní test ověřuje druhý import pomocí lokálního Git transportu; test katalogu ověřuje zachování starého tagu i obnovu po ztrátě odpovědi při tvorbě nového tagu. **Živé ověření aktualizace akce na referenční instanci zůstává otevřené kritérium #130.**

Dependabot v repozitáři platformy upozorňuje na nové upstream verze pomocí PR. Neaktualizuje katalog ani akce instance. Platformní tým musí sledovat releasy platformy a spouštět uvedený postup; pin na SHA interní kopie sám o novém upstream release neinformuje.

### Údržba pinů platformy

`.github/dependabot.yml` kontroluje týdně čtyři umístění: kořenové workflow, `templates/instance/.github/workflows`, acceptance workflow v `tools/acceptance/github` a generované fixtures v `tools/tests/fixtures`. Kořenový záznam `/` prohledává `.github/workflows` a kořenový manifest akce; šablony mimo tento adresář vyžadují vlastní záznam s cestou přímo k YAML souborům. Výběr vlastních adresářů odpovídá [fetcheru Dependabot Core](https://github.com/dependabot/dependabot-core/blob/main/github_actions/lib/dependabot/github_actions/file_fetcher.rb). Úspěšné načtení těchto cest v hostované službě musí autor platformy ověřit v update logu Dependabotu.

Dependabot mění YAML, nikoli PowerShell generátory. Před merge jeho PR musí autor platformy sjednotit nový SHA a komentář tagu ve všech workflow i v `Generate-DeploymentWorkflow.ps1` a `Generate-TeardownWorkflow.ps1`. Potom musí přegenerovat šablony a fixtures:

```powershell
.\tools\Generate-DeploymentWorkflow.ps1
.\tools\Generate-DeploymentWorkflow.ps1 -ModulesPath .\tools\tests\fixtures\modules -OutputPath .\tools\tests\fixtures\deploy.yml
.\tools\Generate-TeardownWorkflow.ps1
.\tools\Generate-TeardownWorkflow.ps1 -ModulesPath .\tools\tests\fixtures\modules -OutputPath .\tools\tests\fixtures\teardown.yml
```

Kontroly `-Check` v Source CI odmítnou rozdíl mezi generátorem a uloženými výstupy. Review major aktualizace musí ověřit použité vstupy a výstupy, minimální verzi runneru a způsob předávání artifactů. Nové major verze `checkout`, `upload-artifact`, `download-artifact`, `setup-terraform` a `Azure/login` používají Node 24. Workflow vyžadují runner alespoň `2.327.1` a používají GitHub-hosted `ubuntu-latest`. `upload-artifact` zachovává výchozí archivovaný přenos. `download-artifact` v8 při neshodě digestu skončí chybou místo varování. Checkout v7 odmítá nebezpečný checkout fork PR; autorizace instance fork PR odmítá už před kandidátním checkoutem. Workflow nesmí kvůli aktualizaci zapnout `allow-unsafe-pr-checkout`.

## Příprava a attestace

`Get-VendoringSource.ps1` nejprve rozliší tag na immutable commit (neměnný commit). ZIP asset vybere z release stejného tagu. Asset musí obsahovat jediný kořenový adresář. Nástroj odmítne traversal, `.git`, duplicitní cesty, symbolické odkazy a rozbalený obsah nad 512 MiB.

Nástroj spočítá SHA256 stažených bajtů a dotáže API attestací pro tento digest. Úspěšná odpověď s prázdnou kolekcí znamená `not-present`. Veřejné API github.com vrací pro neregistrovaný digest také HTTP 404; nástroj tento stav přijme jen po samostatném potvrzení identity a veřejné viditelnosti zdrojového repozitáře a vypíše varování o neověřené provenance. HTTP 404 u privátního zdroje nebo na GHE.com, jiná HTTP chyba, chybějící oprávnění ani nepodporované API nejsou důkazem absence a import zastaví. Nejednoznačný stav vyžaduje deklarovaný ruční import.

Při existující attestaci nástroj stáhne bundle z `bundle_url` každé attestace bez autentizačních hlaviček. Přijme jen HTTPS URL bez přihlašovacích údajů a nejvýše 16 MiB staženého i dekódovaného obsahu. Bundle je komprimovaný formátem Snappy; nástroj ho dekóduje sám. Pak `gh attestation verify <zip> --bundle <soubor>` ověří podpis, digest artefaktu, zdrojový repozitář, `refs/tags/<tag>`, rozlišený source commit a hosted runner (`--deny-self-hosted-runners`). Import pokračuje, když projde aspoň jeden bundle. Neplatná nebo neověřitelná attestace import zastaví ještě před rozbalením. Nástroj zaznamená `verified` až po úspěšném ověření.

Ověření z lokálního bundle nepotřebuje token, protože `gh` nevolá API attestací. Rozhodnutí: nástroj vždy používá `--bundle`. Probe na GitHub-hosted runneru referenční instance GHE.com (gh 2.102.0) ověřil attestaci z github.com i bez `--bundle` a bez tokenu, ale starší verze `gh` bez tokenu selžou. `--bundle` funguje v obou případech. Stejný probe potvrdil síťovou dostupnost github.com, API attestací, úložiště bundle a Sigstore trust root z runneru GHE.com a odmítnutí změněného artefaktu.

Import release (`kind: release`) vyžaduje stav `verified` a signer workflow (podepisující workflow) `<zdroj>/.github/workflows/release.yml`. Stav `not-present` import release zastaví ještě před rozbalením. Signer workflow běží z otagovaného commitu, a proto jeho vlastní kontrola předka `main` nestačí. Import release proto nezávisle ověří přes `GET /repos/{owner}/{repo}/compare/main...{commit}`, že commit tagu je na `main`: `status` musí být `behind` nebo `identical` a `merge_base_commit.sha` musí být tento commit. Jinak se import zastaví před stažením assetu. Attestace platí pro stažený artefakt, nikoli pro všechny soubory release. Automatický zdrojový ZIP akce může mít stav `not-present`; tento stav nikdy neznamená ověřenou provenance (provenienci).

Sdílená IP adresa hosted runneru může vyčerpat limit neautentizovaných požadavků; probe po jednom volání viděl `X-RateLimit-Remaining: 55`. Nástroj při HTTP 403 nebo 429 s vyčerpaným limitem čeká podle `retry-after` nebo `x-ratelimit-reset`, u secondary rate limit bez hlaviček 60, 120 a 240 s. Zkusí nejvýše 3 opakování a čeká nejvýše 300 s. Pak skončí chybou `rate limit for the source is exhausted`.

`ConvertTo-VendoredSource.ps1` přepíše skutečné YAML hodnoty `uses` v composite akcích, včetně vnořených `action.yml` a `action.yaml`. Pro release přepíše kroky a reusable job references v `templates/instance/.github/workflows/`. Nepřepisuje text ve skriptech, komentáře, testovací fixtures ani zdrojové CI, které pod `platform/` neběží jako workflow instance. Vlastníka a repozitář porovnává bez rozlišení velikosti písmen: `Azure/login` odpovídá katalogovému `azure/login`. Katalog vyžaduje kanonické klíče malými písmeny. Shoda musí zahrnout celého vlastníka i repozitář; jinou identitu nástroj odmítne. Subpath akce zachová včetně velikosti písmen a upstream ref nahradí katalogovým SHA. Chybějící katalogová akce způsobí chybu s jejím názvem ještě před vytvořením výstupu.

Lokální `./` odkazy a `docker://` references zůstávají beze změny; nejsou to vzdálené GitHub akce. Docker images musí security tým posoudit zvlášť. Dynamické `uses` a YAML anchors nebo aliases nástroj odmítne místo neúplného přepisu. Import zachová binární soubory. Příprava na Linuxu zapíše executable bits (příznaky spustitelnosti) do manifestu mimo připravený strom; publikace je po artifact přenosu obnoví v souborech i Git indexu. Manifest musí obsahovat právě všechny připravené soubory a boolean příznaky; nesmí obsahovat příkazy ani libovolné filesystem paths (cesty souborového systému). Lokální příprava na Windows bez původních Unix modes (unixových režimů) spustitelnost nezjistí; člověk ji musí doložit z původního archivu nebo provést přípravu na Linuxu.

## Diff, oprávnění a hranice cloudového planu

Příprava a publikace běží v oddělených jobech a předávají jen připravená data, receipt (záznam původu) a mode manifest (manifest příznaků spustitelnosti) přes artifact stejného běhu. Publikace spouští pouze nástroje z důvěryhodné `main`, nikoli skripty kandidáta.

| Environment | App a scope (rozsah) |
|---|---|
| `vendoring-source` | Jen pro privátní zdroj: samostatná enterprise-owned App s přesně `contents: read` a `attestations: read`. Installation token pokrývá jen deklarovaný zdroj. Veřejný import žádný zdrojový klíč nepoužije. |
| `vendoring-action-import` | Samostatná enterprise-owned App s přesně `contents: write` a `pull_requests: write`, instalovaná jen v organizaci akcí. Installation token pokrývá jen cílový repozitář akce. |
| `vendoring-release-import` | Jiná enterprise-owned App se stejnými oprávněními, instalovaná jen v organizaci platformy. Installation token pokrývá jen repozitář instance. |

Všechny tři environmenty musí povolit jen chráněnou `main`. Oba import environmenty musí vyžadovat schválení platformním týmem. Nesmějí obsahovat `workflows: write`, organization administration, Azure nebo Microsoft Graph credentials. Oddělené writer vazby umožňují import do obou organizací, aniž by App získala instalaci v jiné organizaci. Privátní klíče patří jen do příslušných environment secrets, ne do repository nebo organization secrets dostupných běžným jobům. Správu, rotaci po nejvýše 90 dnech a odstranění Apps určuje ADR 0016. Environmenty vytvoří a ochrání `Invoke-GitHubBootstrap.ps1`; importní workflow neprovisionuje environmenty ani identity.

Bootstrap připojí aliasy z `githubApps` parametry `-VendoringReleaseApp`, `-VendoringActionApp` a volitelně `-VendoringSourceApp`. Bez App vazby nechá environment prázdný a vypíše varování; stale credential odmítne. Release writer lze připojit při prvním bootstrapu. Action writer a případný privátní zdroj připoj opakovaným bootstrapem **po apply `actions-catalog`**, se stejným inventory a schválenou konfigurací z `main`. Použij všechny již zapojené App parametry a externí manifest klíčů. Source binding navíc vyžaduje `-VendoringSourceRepository owner/repo`; `-VendoringSourceApiUrl` musí odpovídat API hostu instance. Bootstrap odmítne cross-host source App, protože shoda enterprise slugu na jiném hostu nedokazuje stejnou identitu. Veřejný import z github.com source App nepoužívá. Úplný příkaz a pořadí registrace uvádí [bootstrap](bootstrap.md#zapojení-vendoringu-po-nasazení-katalogu). Ruční změny workflow ani environmentů nejsou součástí tohoto postupu.

Každý environment s App deklaruje `PLATFORM_APP_ID`, `PLATFORM_APP_INSTALLATION_ID`, `PLATFORM_APP_ENTERPRISE` a secret `PLATFORM_APP_PRIVATE_KEY` podle stávajícího tokenového interface. `vendoring-source` navíc deklaruje `SOURCE_REPOSITORY` a `SOURCE_API_URL`; privátní vstupy se s nimi musí shodovat před použitím klíče. `New-PlatformGitHubToken.ps1 -VendoringRepository owner/repo` kontroluje skutečného enterprise vlastníka, přesná oprávnění App a instalací, cílovou organizaci a active selected installation. Token vydá s explicitním omezením na jméno cílového repozitáře a zkontroluje jeho skutečný rozsah. `-ReadOnlySource` zvolí oddělený zdrojový kontrakt. Širší oprávnění způsobí chybu.

Přípravný PR, kterým platformní autor doplňuje `githubApps` nebo `credentials` do `instance.yaml`, má jiný důvod neprovedeného planu než importní PR od App: guard chráněných vazeb záměrně způsobí dva červené checky. Reviewer ověří úspěšnou validaci konfigurace a konkrétní chybu podle [postupu pro chráněné vazby](bootstrap.md#pr-se-změnou-githubapps-nebo-credentials). Cloudový plan proběhne až z chráněné `main` po review a merge.

`Publish-VendoringPullRequest.ps1` vyžaduje čistý checkout cílové `main` a ověřený installation token. Akce vlastní obsah kořene cílového repozitáře kromě `.github/`; upstream `.github/` se neimportuje, aby nepřepsal governance ani nespustil cizí workflow. Release vlastní jen `platform/`. Nástroj odstraní staré tracked soubory uvnitř příslušné hranice a přidá nové; zachová konfiguraci instance i živé workflow. Do `.vendoring.json`, pro release do `platform/.vendoring.json`, zapíše tag, source commit, digest a stav attestace. Licence a ostatní soubory zdroje zůstávají součástí diffu.

Větev má tvar `vendor/<kind>/<SHA256>`. Digest identity vzniká z JSON pole `[kind, source, tag]`: druh a zdrojový repozitář používají malá písmena, tag zachovává velikost písmen. Číslo běhu, pokus běhu ani digest archivu identitu nemění. Volitelný parametr `RunIdentifier` zůstává pro starší workflow; nástroj ho při výpočtu identity nepoužívá.

Záznam původu, commit message, název PR i jeho tělo používají stejné normalizované jméno zdrojového repozitáře. Obnova proto neodmítne stejný zdroj jen kvůli jiné velikosti písmen v dalším receipt. Normalizace nemění tag, source commit ani digest archivu.

Nástroj zjistí SHA vzdálené `main` a načte tento pevný commit; nespoléhá na stáří lokálního checkoutu. Nový import sestaví nad tímto commitem. Opakovaný běh načte existující větev z pevného commit SHA. Kandidáta znovu sestaví nad původním rodičem importu, který musí patřit do historie zachycené vzdálené `main`. Target checkout (checkout cíle) proto obsahuje úplnou historii. Tím obnova zachová původní PR i po posunu `main` mimo hranici vendoringu. Nástroj vyžaduje shodu celého stromu včetně záznamu původu a příznaků spustitelnosti. Jiný obsah, přesunutý tag nebo změněný digest pod stejnou identitou způsobí chybu; nástroj větev nepřepíše. Novou větev publikuje jen tehdy, pokud ještě neexistuje.

Pokud existující větev ještě nemá PR, obnova před jeho vytvořením porovná vlastněnou část původního rodiče se zachycenou vzdálenou `main`. Změna uvnitř této hranice včetně příznaku spustitelnosti způsobí chybu. Chybová zpráva instruuje platformní tým, aby smazal osiřelou větev a spustil import znovu; nástroj větev automaticky nemění ani nemaže. Posun mimo hranici obnově nebrání. Tato výjimka z automatické obnovy chrání před třícestným merge, který by ve vlastněné části ponechal soubory mimo deklarovaný zdroj. Bezprostředně před POST nástroj znovu ověří SHA importní větve i vzdálené `main`. Pokud se `main` mezitím posunula, skončí chybou s pokynem opakovat běh. Stejné ověření vzdálené `main` provede před potvrzením dokončeného sloučeného importu.

Před vytvořením PR nástroj vyhledá všechny otevřené i uzavřené PR pro stejnou zdrojovou větev v cílovém repozitáři, bez filtru cílové větve. Jinou base než `main` nebo více PR odmítne před vzdáleným zápisem; změna base po ztracené odpovědi proto nesmí vytvořit druhý PR. Jediný otevřený PR se shodným head SHA vrátí místo nového PR jen při ověřeném typu autora `Bot` a loginu s doslovnou příponou `[bot]`. Lidského, chybějícího nebo nečitelného autora odmítne, včetně dokumentované nullable varianty `user`. Tato kontrola rozpoznává autora App bota; neověřuje konkrétní App ID.

Ztráta odpovědi po push nebo vytvoření PR nevyžaduje lokální stavový soubor. Pokud člověk otevře PR po vyhledání a před publikací, existující větev se nepřepíše. Chyba vytvoření PR se předá volajícímu a další pokus lidský PR odmítne. Sloučený PR znamená dokončený import bez nových změn jen tehdy, pokud aktuální `main` stále obsahuje celý import včetně metadat a příznaků spustitelnosti. Revert nebo jiná verze ve vlastněné části způsobí chybu; změny mimo hranici vendoringu dokončený import nezneplatní. PR uzavřený bez merge, chybějící větev existujícího PR nebo nečitelný stav také způsobí chybu a vyžaduje zásah platformního týmu. Nástroj PR automaticky neotevírá znovu.

PR otevře installation token, nikoli `GITHUB_TOKEN`. GITHUB_TOKEN workflow má pouze `contents: read` pro checkout důvěryhodných nástrojů. Tokeny se po použití odvolají i při chybě. Chyba push nebo vytvoření PR se nesmí vykázat jako úspěšný import. Nástroj nevynucuje merge ani nevytváří upstream tag v cíli; tagování schválené kopie řeší #15 po review.

PR body a summary uvádějí **Cloud PR plan: NOT PERFORMED**. Deployment authorization odmítne App autora i každý PR se zdrojovou větví `vendor/*` před předáním cloudových credentials. Zákaz větve platí i pro lidského autora z platformního týmu a už při preflight kontrole. GitHub refs rozlišují velikost písmen; autorizační politika záměrně odmítá i prefixy `Vendor/`, `VENDOR/` a ostatní varianty velikosti písmen. Větev `feature/vendor-x` ani `vendoring-docs` tomuto zákazu nepodléhá; její autor musí splnit ostatní autorizační podmínky. Chybějící nebo nečitelný název zdrojové větve také plan nepovolí. Po review a merge do chráněné `main` proběhne nový plan před schváleným apply. Úspěšná příprava, validace YAML, vytvoření PR ani ruční krok nejsou cloudový plan.

### Ruční povýšení živých workflow v #16

Uživatel schválil zachování omezených App oprávnění: automatický import uloží přepsané šablony jen pod `platform/`. Zápis do živých `.github/workflows` by vyžadoval další `workflows: write`; App ho nesmí získat kvůli vendoringu.

Po review release platformní tým připraví samostatný PR s povýšením schválených šablon do `.github/workflows`. Security tým schválí diff a platformní tým zajistí, že workflow používají katalogové SHA a zachovávají authorization gates (autorizační podmínky), environmenty a pořadí plan → approval → apply. Tento ruční krok z #16 se nesmí vykázat jako automaticky ověřený běh. Rozhodnutí upřesňuje acceptance criteria (akceptační kritéria) v [#16](https://github.com/msucharda/devsecops-platform/issues/16#issuecomment-6148995640).

Po mergi povýšení platformní tým nastaví v `instance.yaml` příznak `manualPrerequisites.liveWorkflowsPromoted: true`. Bez příznaku runner zastaví plan a apply modulu `enterprise-baseline`, protože jeho politika akcí by zablokovala workflow s upstream akcemi.

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

Pester testy volají veřejné skripty. Fixtures ověřují přepis composite akcí, zachování lokálních odkazů a script textu, missing catalog error (chybu chybějící katalogové akce), release hranici, tag resolution (rozlišení tagu), attestation failure (selhání attestace), bezpečnost ZIP a omezení installation tokenu. PR test používá skutečný lokální Git a bare repository (holý repozitář); pouze vzdálenou URL přesměruje na lokální repozitář a HTTP API nahradí kontraktními fixtures. `VendoringPullRequest.Interruption.Tests.ps1` ověřuje obě hranice zápisu: push větve a vytvoření PR. Harness zkouší selhání před zápisem i ztrátu odpovědi po zápisu v režimech Error a Abrupt a vyžaduje jedinou větev i PR.

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
- [Výpis PR](https://docs.github.com/en/enterprise-cloud@latest/rest/pulls/pulls#list-pull-requests) a [vytvoření PR](https://docs.github.com/en/enterprise-cloud@latest/rest/pulls/pulls#create-a-pull-request), verze API `2026-03-10`. Kontraktní fixtures přebírají schémata a příklady z [připnutého OpenAPI](https://github.com/github/rest-api-description/blob/755ee33b4a81d51f6f07a902cce26cbec3b822f2/descriptions/ghec/ghec.2026-03-10.json).
- [Rate limits pro REST API](https://docs.github.com/en/enterprise-cloud@latest/rest/using-the-rest-api/rate-limits-for-the-rest-api#exceeding-the-rate-limit) a [artifact attestations](https://docs.github.com/en/enterprise-cloud@latest/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations).
