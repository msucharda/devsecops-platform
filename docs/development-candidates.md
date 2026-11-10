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

Pozitivní Rulesets cyklus zatím blokuje neprokázaná izolace credentials
a opakovatelnost jejich ukončení. Níže uvedené autorizační kontroly ani
lokální snapshot samy tuto podmínku nesplňují. Běžná all-org konfigurace
zůstává určená pro standardní deployment; development ji nesmí obejít.

## Zavedení důvěryhodné cesty

Nejdřív převezmi standardní release obsahující nové nástroje běžným
vendoringem. Samostatným schváleným PR povyš katalogově přepsané šablony
`platform/templates/instance/.github/workflows/deploy.yml` a `development.yml`
do živých workflow. Obě cesty musí používat stejnou ochranu před souběhem.
Před povýšením dokonči nebo výslovně zastav staré deployment runs; jejich
starší workflow nový kontrakt nemají. Tento krok nemění importní oprávnění App
a nesmí nasadit nepřepsané upstream akce. Zachovej stávající environmenty,
schvalovatele, OIDC vazby, omezení deployment App, tokeny i jejich revokaci.

Správce připraví samostatný control ref (řídicí větev)
`refs/heads/platform-control` ve stejném neveřejném repozitáři instance.
Jeho kořenový soubor `development-control.json` obsahuje autoritativní
referenci, source, approval a disposition. Nový reader token ani verifier App
nevznikají. Důvěryhodný nástroj čte záznam existujícím job `GITHUB_TOKEN`
s `contents: read`. Jeho vydání a konec platnosti spravuje
[GitHub pro každý job](https://docs.github.com/en/actions/security-for-github-actions/security-guides/automatic-token-authentication).
Částečně skončený job proto nezanechá nový samostatně vydaný reader token
k obnově v dalším runneru.

Před aktivací musí enterprise ruleset omezit update i deletion této přesné
větve. Žádná candidate-reachable identita ani App nesmí mít bypass ani
pravomoc měnit ruleset nebo jeho vlastníka. Ochrana pouze na úrovni repo
nebo org nestačí, pokud kandidát může získat odpovídající správní pravomoc.
Runtime kontroluje aktivní enterprise update a deletion ze stejného rulesetu;
odpověď branch-rules API sama neprokazuje bezpečnost bypass aktérů.
Tu musí správce doložit samostatným auditem před aktivací.

Audit musí zahrnout skutečné App instalace a effective permissions,
Azure/Graph oprávnění, Entra skupiny a federated credentials všech identit
dosažitelných z kandidáta. OIDC subject každé privilegované fáze musí být
odlišný od subjectů candidate-executing jobs; zkontroluj také další FIC,
flexible expressions a environment branch policies. Immutable subject
obsahuje skutečná owner/repository IDs, nikoli jen jejich názvy.
Neprokázaná izolace aktivaci blokuje. Tato source změna ochrany, refu,
grants ani credentials neprovádí.

Důvěryhodná cesta běží pouze ručním `workflow_dispatch` z chráněné `main`
na pevném `github.sha`. Autorizační nástroje načítá z tohoto commitu
do `trusted/`; kandidáta načítá zvlášť do `candidate/` jako data.
Kandidát se nesmí před živým ověřením sloučit do `main`.

Ve chráněném control refu spravuj mimo kandidáta:

| Pole | Obsah |
|---|---|
| `version` | JSON integer `1`. |
| `reference` | Přesná HTTPS identita povoleného repozitáře včetně hostu: `<server-url>/<owner>/<repo>`. |
| `source` | Výslovná HTTPS identita source repozitáře pro standardní attestaci. |
| `approval` | JSON string obsahující schválení přesného obsahu a operace ve tvaru níže; prázdný string development nepovolí. |
| `disposition` | JSON string s výslovným přechodem na přesný standardní main commit: `adopt` nebo `rollback`; neprázdný string další development zastaví. |

Prázdný záznam před prvním cyklem má například tento tvar:

```json
{
  "version": 1,
  "reference": "https://example.ghe.com/reference-platform/instance",
  "source": "https://github.com/example/platform",
  "approval": "",
  "disposition": ""
}
```

Approval a disposition vlož jako serializované JSON strings; následující
příklady zobrazují jejich dekódovaný obsah. Každá změna control commitu
zneplatní rozpracované běhy a vyžaduje nový dispatch. Původní environment
proměnné nejsou náhradním zdrojem autorizace.

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

Nástroj navíc odvodí chráněnou executable closure (vykonávané závislosti)
z deklarovaných Azure/Graph/directory oprávnění, enterprise App pravomocí
a organization membership write. Zahrne všechny prerequisites, runtime,
ověřování závislostí, vendored parser a celé příslušné moduly včetně provider
lockfiles a hooků. Jejich přidání, změnu ani odstranění kandidát nesmí provést.
Tyto fáze běží pouze z ověřené baseline a jejich prerequisites stahují
neměnné artifacts podle ID z trusted `needs` outputs, nikoli podle názvu.
Přepsání artifactu vytváří jiné ID; odstranění původního download zastaví.
Kontrakt popisují připnuté akce
[`upload-artifact`](https://github.com/actions/upload-artifact/tree/v7.0.2#not-uploading-to-the-same-artifact)
a [`download-artifact`](https://github.com/actions/download-artifact/tree/v8.0.2#download-artifacts-by-id).

V současném grafu jde o `emu-identity`, `organizations` a
`organization-roles`. Změny jejich autorizační implementace patří do
standardního release. Ostatní candidate-executing fáze nesmějí získat
enterprise App ani write autoritu nad referenčním repo. Kontrola odmítne
také organization a neznámé write permissions ve vlastnické organizaci
reference, i když instalace nevybírá žádné repozitáře. Pouze známá
repository-only oprávnění `contents`, `administration`, `actions`
a `workflows` může přijmout nad výslovně jinými repozitáři.

Samotné spuštění baseline v jiném kroku nestačí. Candidate job nesmí
získat její identitu přes OIDC, minting endpoint ani zachovaný klíč.
Private key vložený do stejného runneru jako kandidát se nepovažuje
za nedostupný po ukončení kroku. Pozitivní Rulesets cesta musí navíc
prokázat serverový scope vydaného tokenu, jeho ukončení a bezpečný další
cyklus. Současný all-org App kontrakt tyto podmínky neplní a kontrola jej
pro kandidáta odmítne před vydáním credentials.

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
vydáním deployment App tokenu použije job token pro aktuální read-only
načtení control refu. Kontroluje aktuální referenci,
source, approval a disposition, nikoli jejich kopii z prvního jobu.
Nahrazení nebo odstranění approval, změna reference/source i nastavená
disposition development zastaví. Časové freshness okno není náhradní
autorizační cesta.

Reader používá GitHub REST API `2026-03-10`:
[`GET /repos/{owner}/{repo}/git/ref/{ref}`](https://docs.github.com/en/enterprise-cloud@latest/rest/git/refs#get-a-reference),
[`GET /repos/{owner}/{repo}/git/trees/{tree_sha}`](https://docs.github.com/en/enterprise-cloud@latest/rest/git/trees#get-a-tree),
[`GET /repos/{owner}/{repo}/contents/{path}`](https://docs.github.com/en/enterprise-cloud@latest/rest/repos/contents#get-repository-content)
[`GET /repos/{owner}/{repo}/rules/branches/{branch}`](https://docs.github.com/en/enterprise-cloud@latest/rest/repos/rules#get-rules-for-a-branch)
a [`GET /repos/{owner}/{repo}/rulesets/{ruleset_id}`](https://docs.github.com/en/enterprise-cloud@latest/rest/repos/rules#get-a-repository-ruleset)
s `includes_parents=true`. Teprve úplný ruleset má dokumentovanou variantu
`source_type: Enterprise`; typ zdroje z branch-rules ji nenahrazuje.
Reader vyžaduje aktivní branch ruleset s update i deletion ochranou
a výslovným `update_allows_fetch_and_merge: false`.
Nejdřív ověří čtení známé `main`; teprve poté může standardní non-reference
repo přijmout chybějící control ref. Nečitelný soukromý repozitář není
non-reference fallback. Tree i file se čtou z pevného control SHA, tree
musí být úplný a soubor musí být regular blob `100644`, nejvýš 64 KiB.
Contents API může dereferencovat symlink, proto samotné `type: file` nestačí.
Reader odmítne neúplný či neznámý tvar, duplicitní pole včetně case-only
variant, nesprávnou velikost, neplatné UTF-8 i změnu refu během čtení.
Kontrolní commit musí zůstat stejný také proti authorize jobu.
Po síťových krocích nástroj znovu posoudí expiraci schválení.
Čtení konfigurace a vydání deployment tokenu nejsou jedna atomická GitHub
transakce; kontrakt neumožňuje cache ani opětovné použití starého výsledku.

„Re-run failed jobs“ ani opakování celého starého workflow nepovolí
credentials; vytvoř nový dispatch. Zdrojový repozitář attestace musí
odpovídat čerstvému chráněnému stavu i původnímu authorize jobu.
Každá standardní fáze navíc vyžaduje `authorize` ze stejného run attempt.
Starý běh s původně prázdnou referencí tak nesmí přeskočit nově nastavenou
ochranu. Mimo referenci lze zopakovat všechny joby včetně nové autorizace;
samotné opakování neúspěšných jobů nestačí ani tam.
Závěrečný job `deployment_complete` odmítne starý authorize attempt i přeskočenou
vybranou apply fázi. Přeskočení deploy jobů proto nesmí změnit neprovedený apply
na úspěšný výsledek workflow.

Tato cesta není sandbox schváleného kódu. Review musí posoudit i zachování
token lifecycle: schválený modul se stejnými oprávněními procesu může měnit
prostředí jobu. Samotné ověření cest a hashe nedokazuje bezpečnost jeho chování.

Původ PR se čte read-only workflow tokenem přes
[`GET /repos/{owner}/{repo}/pulls/{pull_number}`](https://docs.github.com/en/enterprise-cloud@latest/rest/pulls/pulls#get-a-pull-request),
REST API `2026-03-10`. Nullable nebo neúplné identity neautorizují běh.
Membership a vydání/revokace tokenů používají stávající trusted nástroje.

## Lokální snapshot state

`New-DevelopmentStateSnapshot.ps1` ověří a lokálně zkopíruje přesné bajty
jednoho standardního organization rootu. Podporuje pouze
`organization-rulesets`: resource-free `main` a úplný `rulesets` root
jediné organizace. Kontroluje resource addresses, instances i organization
attributes; nevybírá organizaci z all-org state a nepřepisuje state JSON.
Manifest váže snapshot na lineage, serial, SHA256, source key a ETag
i přesné baseline, candidate a control revize.
Strukturální pole Terraform state musí mít kanonické názvy z malých ASCII
písmen, číslic a podtržítek. Go JSON decoder přijímá i case-only varianty,
které PowerShell dictionary rozlišuje; stejný soubor by jinak mohl projít
kontrolou jako root resource a v Terraformu znamenat nested module.

Nástroj nečte Azure, neověřuje vzdálený ETag a nevydává credentials.
Vstupní bajty, očekávaný digest a ETag musí dodat trusted čtení přesného
standardního backendu pod společnou concurrency ochranou. Publikace
lokálního state a manifestu používá staging adresář a atomické přejmenování;
opakování odmítne změněný výsledek nebo cizí soubory. Celou publikaci včetně
obnovy staging chrání exclusive file lease. Souběžný publisher nesmí
rozpracované soubory přepsat. Lock soubor zůstává na disku; ukončení procesu
uvolní jeho OS handle. Nástroj před úspěchem znovu ověří publikované bajty
i manifest.

Regresní test spustí dva skutečné procesy nad stejným cílem a různými
vstupními state i provenance. První publisher pozastaví před atomickým
přejmenováním se získanou lease. Druhý musí odmítnout zápis bez změny staging;
po uvolnění lease musí odmítnout nahrazení dokončeného snapshotu. Test ověří
původní bajty lock souboru, oba nezměněné vstupy a nerozmíchaný publikovaný
state s manifestem. Patří do běžné kontraktní sady Source CI i mutací
publikační kontroly. Lokální Windows výsledek nenahrazuje Linux CI.

Lokální kontraktní test přes skutečný `Invoke-Module -Backend local`
ověřuje přesný snapshot v cestě
`<StatePath>/organization-rulesets/organizations/<org>/terraform.rulesets.tfstate`,
jediný org token, candidate apply a následný prázdný plan. Kandidátní fixture
připouští pouze přesný předchozí ruleset při zpřísnění review vláken.
Standardní backend guard ani all-org deklaraci tento test neobchází.
Tento test není důkaz živého běhu, VM izolace ani ukončení tokenu.

Tento helper zatím není zapojený do candidate workflow. Neprokazuje
cloud state scope, retirement identity ani standardní adopt/rollback.
Candidate-written state se nesmí vracet do standardního backendu.
Standardní root musí použít vlastní state a ověřený reconcile živého
objektu. Při rollback nejdřív ověř, zda starý release změněný objekt přijme;
samotná dispozice jeho drift guard nemění.

## Současné běhy a přerušení

Development workflow sdílí concurrency `deploy-instance-main` se
standardním main deploy. Dokud existuje externí development schválení bez
platné dispozice, standardní deploy odmítne credentials. Expirace schválení neznamená
vrácení živého stavu a lock automaticky neuvolní. Plánovaný drift dál
porovnává skutečnost se standardním release; jeho nález není úspěšné
ověření development kandidáta.

Standardní plan i apply na povolené referenci používají stejné čerstvé čtení
uvnitř phase po jejím review. Aktuální approval/disposition ověří před Azure
login i před App tokenem; změna, odvolání nebo expirace dispozice během čekání
tak neprojde jen kvůli dřívějšímu authorize jobu. Zmizelý nebo nově vytvořený
control ref proti authorize snapshotu také zastaví credentials.

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
