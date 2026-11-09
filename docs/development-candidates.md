# Development candidate na referenční instanci

Development mode (vývojový režim) ověří přesný PR repozitáře instance nad
ověřeným release. Používá samostatnou šablonu `development.yml`; standardní
`deploy.yml` kandidáta nepřijme jako release. Postup provádí pouze oprávněný
platformní tým na výslovně povolené referenční instanci podle
[ADR 0019](adr/0019-reference-development-candidates.md).

Tento dokument ani záznam cyklu nepovolují živý běh. Nastavení proměnných,
povýšení workflow, konkrétní plan nebo apply, vydání release a destruktivní
ověření vyžadují odpovídající konkrétní souhlas. Zdroj neobsahuje skutečný
cíl reference ani její provozní důkazy.

## Zavedení důvěryhodné cesty

Nejdřív převezmi standardní release obsahující nové nástroje běžným
vendoringem. Samostatným schváleným PR povyš katalogově přepsané šablony
`platform/templates/instance/.github/workflows/deploy.yml` a `development.yml`
do živých workflow. Obě cesty musí používat stejnou ochranu před souběhem.
Před povýšením dokonči nebo výslovně zastav staré deployment runs; jejich
starší workflow nový kontrakt nemají. Tento krok nemění importní oprávnění App
a nesmí nasadit nepřepsané upstream akce. Zachovej stávající environmenty,
schvalovatele, OIDC vazby, omezení deployment App, tokeny i jejich revokaci.

Zavedení navíc vyžaduje samostatně schválenou verifier App (ověřovací App).
Její jediná volitelná pravomoc je repository `Environments: read`; implicitní
`Metadata: read` se nezvyšuje. App má právě jednu organization installation
se `repository_selection: selected` a právě jedním repozitářem instance.
Nesmí sdílet klíč s membership ani deployment App a nesmí mít write oprávnění.
GitHub tuto pravomoc neumí omezit jen na `pr-authorization`: dosáhne na
environment metadata a proměnné celého vybraného repozitáře, nikoli na hodnoty
jeho secrets. Toto omezení scope patří do žádosti o souhlas.

Správce uloží následující vazby mimo kandidáta do každého použitého plan,
ruleset-plan a apply environmentu:

| Vazba | Typ a obsah |
|---|---|
| `PLATFORM_APPROVAL_READER_APP_ID` | Chráněná proměnná s přesným App ID. |
| `PLATFORM_APPROVAL_READER_INSTALLATION_ID` | Chráněná proměnná s přesným installation ID. |
| `PLATFORM_APPROVAL_READER_ENTERPRISE` | Chráněná proměnná s očekávaným vlastníkem App. |
| `PLATFORM_APPROVAL_READER_PRIVATE_KEY` | Chráněný secret se samostatným klíčem verifier App. |

Vznik App, installation, grant i zápis klíče vyžadují konkrétní živý souhlas.
Source změna nic z toho neprovádí. `GITHUB_TOKEN` nemá workflow permission
`environments`; obecné `actions: read` tuto pravomoc nenahrazuje.

Důvěryhodná cesta běží pouze ručním `workflow_dispatch` z chráněné `main`
na pevném `github.sha`. Autorizační nástroje načítá z tohoto commitu
do `trusted/`; kandidáta načítá zvlášť do `candidate/` jako data.
Kandidát se nesmí před živým ověřením sloučit do `main`.

V chráněném environmentu `pr-authorization` spravuj mimo kandidáta:

| Proměnná | Obsah |
|---|---|
| `PLATFORM_REFERENCE_REPOSITORY` | Přesná HTTPS identita povoleného repozitáře včetně hostu: `<server-url>/<owner>/<repo>`. |
| `PLATFORM_SOURCE_REPOSITORY` | Environment-level kopie stejného source override jako ve standardní release cestě, pokud je override nastavený. Samotná repository-level nebo organization-level hodnota pro development nestačí; reader ji nemůže ověřit bez dalších oprávnění. Bez override obě cesty používají výchozí source důvěryhodného nástroje. |
| `PLATFORM_DEVELOPMENT_APPROVAL` | Samostatně udělené schválení přesného obsahu a operace ve tvaru níže. Prázdná hodnota development nepovolí. |
| `PLATFORM_DEVELOPMENT_DISPOSITION` | Výslovný přechod na přesný standardní main commit: `adopt` nebo `rollback`. Neprázdná hodnota další development zastaví. |

Pouze správce této důvěryhodné konfigurace smí schválení zapsat. Kandidát,
soubor v jeho PR ani jeho vlastní workflow nejsou zdrojem oprávnění.
Nastavení nesmí být dostupné pro zápis žádnému tokenu vydávanému kandidátovi.
`approvedBy` a `approvalUrl` odkazují na skutečné konkrétní schválení;
jejich text sám o sobě nikoho neautorizuje.

```json
{
  "version": 1,
  "repository": "https://example.ghe.com/reference-platform/instance",
  "baseRevision": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "revision": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "digest": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
  "pullRequest": "42",
  "operation": "apply",
  "approvedBy": "reviewer",
  "approvalUrl": "https://example.ghe.com/reference-platform/instance/pull/42#approval",
  "expiresAt": "2026-12-01T12:00:00.0000000+00:00"
}
```

`baseRevision` je přesný commit chráněné `main`, ze kterého poběží workflow.
Jeho `platform/` musí projít nezměněným standardním ověřením attestace,
markeru a úplného obsahu release. Kandidát musí být potomkem tohoto
commitu. Posun base, PR headu, obsahu nebo změna `plan` na `apply`
vyžaduje nové schválení.

## Příprava a běh kandidáta

Připrav lidský PR ze stejného repozitáře do `main`. Fork, App autor,
vendoring větev, draft, uzavřený nebo sloučený PR neprojde. Autor musí
zůstat aktivním členem chráněného platformního týmu; nová cesta toto
ověření nenahrazuje schválením kandidáta.

Kandidát může měnit implementaci pod `platform/modules/` a neautorizační
nástroje pod `platform/tools/`. Nesmí měnit `module.yaml`, oprávnění,
konfiguraci instance, katalog, marker, živé workflow ani autorizační
a credential nástroje. Taková změna vyžaduje standardní source PR
a release, nikoli samoautorizaci kandidáta. Review změny nadále posoudí
její skutečné chování; povolená cesta souboru není bezpečnostní schválení.

Na čistém checkoutu přesného PR headu získej digest důvěryhodným nástrojem
mimo kandidáta:

```powershell
Import-Module <trusted-release>\platform\tools\DevelopmentCandidate.psm1
Get-DevelopmentCandidateSnapshot -Path <candidate-checkout>
```

Digest je SHA256 kompaktního JSON pole `[cesta, Git režim, SHA256 souboru]`
pro všechny tracked soubory v pořadí Git tree. Zahrnuje celý repozitář,
nejen změněné soubory. Kontrola navíc porovná skutečné pracovní bajty
s HEAD, takže ji neobejdou `assume-unchanged` ani `skip-worktree`.
Symlink, submodule, necommitnutý, nový nebo ignorovaný payload kontrola
odmítne. Jedinou výjimkou mimo kandidáta je ověřovaná cache závislostí
důvěryhodného runtime pod `platform/tools/.dependencies/`.

Po review a konkrétním schválení spusť `Develop reference instance`
s číslem PR, plným SHA, scope a operací. Výchozí operace je `plan`.
`apply` musí samostatně projít stávajícím `approve-apply`; jeho následné
module jobs zachovávají existující phase environmenty a oprávnění.
Před prvním App klíčem i před credentials každé fáze nástroj znovu
ověří přesný kandidát, schválení, expiraci a standardní výchozí release.
Nečitelný nebo neúplný stav běh zastaví. Kandidát nikdy nerozhoduje
o vlastním povolení.

Po review konkrétního phase environmentu trusted nástroj znovu ověří kandidáta
a aktuální PR head, base i stav. Bezprostředně před Azure login a znovu před
vydáním deployment App tokenu použije oddělenou verifier App pro aktuální
read-only načtení proměnných `pr-authorization`. Kontroluje aktuální referenci,
source, approval a disposition, nikoli jejich kopii z prvního jobu.
Nahrazení nebo odstranění approval, změna reference/source i nastavená
disposition development zastaví. Časové freshness okno není náhradní
autorizační cesta.

Verifier používá
[`GET /repos/{owner}/{repo}/environments/{environment_name}/variables`](https://docs.github.com/en/enterprise-cloud@latest/rest/actions/variables#list-environment-variables),
API `2026-03-10`, s repository
[`Environments: read`](https://docs.github.com/en/rest/authentication/permissions-required-for-github-apps#repository-permissions-for-environments).
Všechny proměnné musí být v jedné úplné odpovědi, nejvýš 30 záznamů
podle připnutého kontraktu API;
neúplná stránka, chybějící reference, duplicitní jména včetně rozdílu jen
ve velikosti písmen, chyba API i neznámý
stav běh zastaví. Nástroj nevypisuje hodnoty. Před uvolněním deployment
credentials prokáže revokaci reader tokenu pomocí HTTP 204 a následného
HTTP 401. Po těchto síťových krocích znovu posoudí expiraci schválení.
Čtení konfigurace a vydání jiného tokenu nejsou jedna atomická GitHub
transakce; kontrakt neumožňuje cache ani opětovné použití starého výsledku.

„Re-run failed jobs“ ani opakování celého starého workflow nepovolí
credentials; vytvoř nový dispatch. Zdrojový repozitář attestace musí
odpovídat čerstvému chráněnému stavu i původnímu authorize jobu.

Tato cesta není sandbox schváleného kódu. Review musí posoudit i zachování
token lifecycle: schválený modul se stejnými oprávněními procesu může měnit
prostředí jobu. Samotné ověření cest a hashe nedokazuje bezpečnost jeho chování.

Původ PR se čte read-only workflow tokenem přes
[`GET /repos/{owner}/{repo}/pulls/{pull_number}`](https://docs.github.com/en/enterprise-cloud@latest/rest/pulls/pulls#get-a-pull-request),
REST API `2026-03-10`. Nullable nebo neúplné identity neautorizují běh.
Membership a vydání/revokace tokenů používají stávající trusted nástroje.

## Současné běhy a přerušení

Development workflow sdílí concurrency `deploy-instance-main` se
standardním main deploy. Dokud existuje externí development schválení bez
platné dispozice, standardní deploy odmítne credentials. Expirace schválení neznamená
vrácení živého stavu a lock automaticky neuvolní. Plánovaný drift dál
porovnává skutečnost se standardním release; jeho nález není úspěšné
ověření development kandidáta.

Standardní plan i apply na povolené referenci používají stejný čerstvý reader
uvnitř phase po jejím review. Aktuální approval/disposition ověří před Azure
login i před App tokenem; změna, odvolání nebo expirace dispozice během čekání
tak neprojde jen kvůli dřívějšímu authorize jobu. Neprázdná approval/disposition
vyžaduje toto ověření i po odstranění konfigurační hodnoty reference.

Změna živého stavu může přežít selhání workflow. Po přerušení zapiš stav
`interrupted`, zjisti skutečný stav a použij obnovu příslušného modulu.
Nový workflow run má čerstvý checkout a znovu ověří všechny podmínky.
Částečně materializovaný preflight v témže pracovním adresáři se nesmí
přijmout jako dokončené ověření. Nástroje samy neschvalují opakování,
nevracejí změnu a neodstraňují externí lock.

## Soukromá evidence a dokončení

Ulož verzovaný záznam do `development-cycles/<cycle-id>.json` neveřejného
repozitáře instance. Příklad `development-cycle.example.json` je pouze
neúplná šablona, nikoli důkaz běhu nebo schválení.
Záznam udržuj v samostatné evidence větvi/PR mimo obsah kandidáta.
Hash kandidáta nesmí záviset na záznamu, který sám obsahuje tento hash.
Posun `main` v průběhu běhu mění trusted base a vyžaduje nové schválení;
evidence PR proto nezaměňuj za bezvýznamný provozní zápis.

Záznam obsahuje výchozí release, base/head SHA, digest, přesnou změnu
a objekty, PR, konkrétní schválení, výsledek a převzetí do release
nebo vrácení. UI/API experiment navíc před zápisem eviduje schválený
rozsah, původní hodnoty, všechny změněné objekty a způsob jejich
kodifikace nebo vrácení. Nejasný stav zůstává nedokončený.

`verificationPlan` posoudí bootstrap, teardown, obnovu a akceptační milník.
Potřebný destruktivní scénář uveď samostatně s jeho konkrétním schválením
a důkazem; do té doby ponech `destructiveStatus: unverified`.
To neuzavírá #246 ani jiná dotčená otevřená kritéria.

Po prvním živém výsledku doplň `firstLive` s `at`, přesným `revision`,
`digest`, skutečným `result: passed` nebo `failed` a `evidenceUrl`.
Neúspěšný výsledek ani jeho čas nepřepisuj pozdějším úspěchem. Pokud první
pokus selhal, ulož pozdější úspěšné ověření do `successfulLive` se stejnými
poli; musí následovat po `firstLive` a před standardním release.
Neúplný cyklus ponechá skutečný první výsledek i měření, ale nedostane
stav dokončeného ověření. Zobecni změnu v source PR
bez dat instance, vydej konkrétně schválený standardní release
a převezmi ho běžným importem. Použij dosavadní github.com cestu až
do výslovně schváleného přepnutí; development nástroje hosty nepřepínají.
Po review a přijetí přesného standardního importu obsahujícího zobecněnou
změnu, nebo po schválení návratu, správce nejdřív nastaví chráněnou dispozici.
Ta zastaví další development a povolí standardní běh pouze z určeného main SHA:

```json
{
  "version": 1,
  "operation": "adopt",
  "repository": "https://example.ghe.com/reference-platform/instance",
  "mainRevision": "<full-standard-main-sha>",
  "candidateRevision": "<full-approved-candidate-sha>",
  "candidateDigest": "<approved-candidate-sha256>",
  "approvedBy": "reviewer",
  "approvalUrl": "https://example.ghe.com/reference-platform/instance/pull/43#approval",
  "expiresAt": "2026-12-01T12:00:00.0000000+00:00"
}
```

`rollback` má stejný kontrakt a určuje přesný známý standardní main commit.
Dispozice nezruší review, attestaci, standardní main-only apply ani schvalovací
environmenty. Nejprve dokonči tento standardní běh a zapiš soukromé důkazy.
Teprve potom správce odstraní approval i disposition. Při chybě nebo přerušení
je ponechá; standardní re-run credentials neobnoví, nový dispatch znovu ověří
dispozici. Nevzniká tak kruh mezi lockem a potřebným standardním deploy.
Samotné odstranění obou hodnot cyklus nedokončuje a nesmí zakrýt chybějící důkaz.

`standardRelease` uvádí `verifiedAt`, `tag`, `platformRevision`,
`instanceRevision`, source/import PR a `evidenceUrl`. Jeho `scenarios`
obsahují `functional`, `forbidden`, `idempotence` a `drift`. Každý použitý
scénář uvádí `result: passed`, `scenario`, `expected`, `actual`
a `evidenceUrl`; revize přebírá z tohoto release záznamu. Opakovaný apply
musí mít `changes: 0`, drift `unexpectedDrift: false`. Nepoužitelný
scénář kromě funkčního má `result: notApplicable` s konkrétním `reason`.
Dokončený záznam dále vyžaduje `dispositionEvidenceUrl` a `approvalRemovedAt`
nejdřív po `standardRelease.verifiedAt`. Tag musí být jiný než výchozí release
a instance SHA se nesmí rovnat výchozímu main ani development headu. Návrat
na původní baseline není standardní dokončení změny.
Chybějící důkaz ani neočekávaný drift nejsou úspěch.

Měř oba úseky pomocí `readyAt`, `firstLive.at` a
`standardRelease.verifiedAt`. `intervals` pokrývají čas od `readyAt`
do `observedUntil` bez mezer a překryvů; `kind` rozlišuje `work`, `ci`
a `humanWait`. U souběhu eviduj druh kritické cesty, nesčítej
wall-clock čas souběžných aktivit. Přerušený nebo vrácený cyklus se
nesmí vykázat jako dokončené ověření standardního release.

```powershell
.\platform\tools\Test-DevelopmentCycle.ps1 -RecordPath .\development-cycles\<cycle-id>.json
.\platform\tools\Test-DevelopmentCycle.ps1 -RecordPath .\development-cycles\<cycle-id>.json -RequireComplete
```

Validátor ověřuje strukturu a časové údaje záznamu, nikoli pravdivost
vzdálených receipts. Výstup je **nahlášená evidence**, dokud ji vlastník
akceptace nezávisle neověří. Číselný cíl a tvrzení o zrychlení vyžadují
následné vyhodnocení skutečných měření podle ADR 0002.
