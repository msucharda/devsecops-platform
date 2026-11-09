# Pilot vývoje na GHE.com

Pilot ověřuje cílovou cestu podle [ticketu A](https://github.com/msucharda/devsecops-platform/issues/258)
a [spec #256](https://github.com/msucharda/devsecops-platform/issues/256).
**Není přepnutím každodenní práce.** Do konkrétně schváleného přepnutí zůstává
dosavadním místem práce github.com. Pilot nevydává release, nepřenáší otevřená
issues a nezavádí obousměrnou synchronizaci.

Tento runbook obsahuje zdrojový inventář a postup ověření, nikoli doklad
provedeného pilotu. Konkrétní host, organizace, identity, konfigurace instance
a provozní receipts patří do neveřejného záznamu. Úspěšné offline testy
nenahrazují živá kritéria A1 až A4.

## Souhlas a výchozí stav

Před prvním zápisem musí uživatel schválit konkrétní organizaci, repozitář,
aktéra, přenášenou revizi a operace pilotu. Výběr názvu není souhlas s vytvořením
organizace. Samostatný souhlas vyžadují změny členství, přístupů, Apps,
Actions politik, rulesets, licencí a sdílených nastavení. Chybějící předpoklad
znamená blokaci; nesmí vést k rozšíření oprávnění nebo vypnutí kontroly.

Neveřejný výchozí záznam musí určit:

- přijaté source SHA, cílový host a repozitář, původní místo přijímání práce;
- schváleného uživatele a jeho skutečnou identitu z `GET /user`;
- revizi konfigurace reference, instalovaný release a původ jeho workflow;
- rozsahy organizační správy a uloženého state, bootstrap inventory a plán
  zachování vývoje při odstranění reference;
- výchozí nastavení CI, review, rulesets a sdílené závislosti včetně plánů návratu.

Před přenosem zdroje ověř hranici veřejných a neveřejných dat. Přenášej pouze
schválené source refs. Nevytvářej release tag: přenesený `release.yml`
reaguje na tagy `v*`. Přenos historie, vytvoření PR a spuštění CI jsou živé
zápisy, i když jde o soukromý cílový repozitář.

## Inventář integrací

Stav **zdrojově pokryto** znamená implementaci nebo existující zdrojový kontrakt.
Neznamená funkčnost na konkrétním GHE.com hostu. Pro každou položku doplň
v neveřejném záznamu přesnou revizi, skutečný výsledek, čas a případný blocker.

| Plocha | Host, identita a konkrétní operace | Zdrojový kontrakt a potřebný živý důkaz |
|---|---|---|
| `tools/GitHubHost.psm1` | `[host/]owner/repo`; lokální `gh`, případně konkrétní existující účet přes `-GitHubUser` volajícího nástroje. | Sdílený parser a výběr účtu bez globálního `gh auth switch`. Pro jiný host než github.com odstraní implicitní `GH_TOKEN` i `GITHUB_TOKEN` a použije uložené přihlášení cílového hostu. Konkrétní účet získá token pouze z jeho uloženého přihlášení. Ověř skutečného aktéra a přístup ke konkrétnímu repozitáři. |
| `tools/Wait-PullRequestChecks.ps1` | Cílový REST API origin; `GET` PR, workflow runs, check runs, reviews a requested reviewers. Pro privátní repo potřebuje účet přístup k PR a čtení Actions a Checks; samotný přístup k veřejnému source nestačí. | Host určí z explicitního repozitáře nebo HTTPS/SSH originu. `-ApiUrl` musí být cloudový HTTPS API origin a nesmí odporovat explicitnímu hostu repozitáře. Výsledek patří přesnému head SHA; neúplná či nekonzistentní stránka nesmí být `passed`. Timeout zůstává `pending`, HTTP nebo kontraktní chyba je `error`. Jde o pozorování, nikoli merge gate. |
| `tools/agents/Test-MergeGate.ps1` | Cílový host; REST a GraphQL reads PR, pravidel, CI, review, pevných commitů a stromů. Vyžaduje viditelnost všech vstupů gate včetně pravidel repozitáře. | Zachovává G1–G11, požadované `Source CI`, review, pevné head/base SHA a potvrzení citlivých workflow změn. Ověř přesné required-check kontexty a jejich cílová `integration_id`; ID App z github.com nelze pokládat za ID App v GHE.com. Chybějící přístup nebo neúplná odpověď není pass. |
| `tools/agents/Invoke-GatedMerge.ps1` | Tentýž host a aktér; čerstvá evaluace a jediný squash merge přes `--match-head-commit`, potom readback. | Pilot jej nesmí spustit bez konkrétního merge mandátu. Samotné `pass` není souhlas. Publikaci ani převod PR schválení mezi hosty tento nástroj neřeší. |
| `.github/workflows/ci.yml` | GHE.com repozitář; jeho vlastní `GITHUB_TOKEN`, `contents: read`; GitHub-hosted Linux runners a pinované externí akce. | Zdrojový workflow nepoužívá Azure credential, App instance ani publisher. GHE pilot musí skutečně dokončit statické kontroly, Pester, Terraform, interruption harness a mutace beze změny kategorií či agregátů. Ověř Actions dostupnost, schválené upstream SHA, síťové zdroje a přístup k artefaktům. Nedostupnou akci nebo runner nenahrazuj vynecháním jobu. |
| Review a lokální gate | Existující lokální nástroje, lidské a Copilot review na cílovém hostu. | Commit-bound lokální gate před každým pushem a úplné Linux Source CI na přesném head SHA zůstávají povinné. Ověř dostupnost Copilot review, členství reviewerů a potřebnou licenci/politiku; nedostupnost neopravňuje k vypnutí požadavku. |
| Tracker a odkazy | Issues a PR cílového repozitáře, s jednoznačným hostem a mapováním původu. | Pilot nepřenáší tracker. Otevřenou práci a odkazy řeší [ticket C](https://github.com/msucharda/devsecops-platform/issues/261), až po splnění skutečných předpokladů. Historické odkazy na github.com se automaticky nepřepisují na stejné číslo v GHE.com. |
| Workflow a identity instance | Host z neveřejné konfigurace; oddělené module Apps, plan/apply identities, OIDC a chráněné environments. | Nejsou identitou source CI. Pilot nesmí získat klíče, Azure role ani instalace Apps reference. Jejich lifecycle a scope se nemění přidáním source repozitáře do stejného enterprise. |
| `.github/workflows/release.yml`, `Publish-PlatformRelease.ps1`, `Test-DeploymentRelease.ps1` a vendoring | Veřejný github.com source a release; build, OIDC attestace a standardní import. | Veřejná distribuce zůstává na github.com. Kontrola release a jeho signer workflow se nepřesměruje na neveřejný pilot. Funkční publikaci stejného SHA, celou přenášenou historii a úplný RC průchod prokazuje [ticket B](https://github.com/msucharda/devsecops-platform/issues/260). |
| Publisher | Samostatná GitHub App jen pro veřejný repozitář, bez identity source CI, instance a osobního PAT. | Přesné operace a oprávnění, včetně přenosu změn workflow a respektování ruleset, musí doložit B. Inventář z A je nesmí označit za ověřené na základě předpokládaného `contents: write`. |

`GH_TOKEN` a `GITHUB_TOKEN` podle [kontraktu gh](https://cli.github.com/manual/gh_help_environment)
platí pro github.com **i subdomény ghe.com**. `GH_ENTERPRISE_TOKEN` a
`GITHUB_ENTERPRISE_TOKEN` jsou pro GitHub Enterprise Server, nikoli náhradní
výchozí tokeny pro GHE.com. Proto samotný `--hostname` neodstraní chybně
zděděný cloudový token. Adaptér všechny původní tokenové proměnné po volání
obnoví i při chybě; nevypisuje jejich hodnoty a nemění aktivní účet ani scopes.

Waiter použije zděděné `GITHUB_API_URL` jen pro repozitář bez hostu.
Explicitní host nebo host z originu má přednost před tímto výchozím nastavením;
explicitní `-ApiUrl` se s hostem nadále musí shodovat. SSH origin pro GHE.com
používá jako uživatelské jméno subdoménu enterprise, nikoli vždy `git`.
Výchozí github.com cesta s `GH_TOKEN` nebo `GITHUB_TOKEN` nevyžaduje `gh`;
konkrétní uložený účet a jiné hosty jej vyžadují.

Příklady používají pouze zástupné cíle a existující přihlášení:

```powershell
.\tools\Wait-PullRequestChecks.ps1 -Repository example.ghe.com/example-development/source -Pr 1 -GitHubUser pilot-owner
.\tools\agents\Test-MergeGate.ps1 -Repository example.ghe.com/example-development/source -Pr 1 -ExpectedHeadSha <head-sha> -GitHubUser pilot-owner
```

První příkaz nenahrazuje druhý. Ani druhý příkaz nepovoluje merge. Při chybě
přihlášení nejdřív ověř názvy přítomných tokenových proměnných a účet pro daný
host; tokeny nevypisuj. Nedostupný konkrétní účet se nesmí tiše nahradit jiným.
Nové přihlášení a rozšíření přístupu patří oprávněnému uživateli.

## Nedestruktivní důkaz hranice správy

Podle [ADR 0004](../adr/0004-instance-owns-enterprise-and-tenant.md) zůstává
organizace pro vývoj platformy mimo organizační správu reference. Samotné
odlišné jméno nestačí: ověř konfiguraci, uložený state i provozní inventory.
Nevyvolávej `destroy`, teardown workflow ani `Remove-Bootstrap.ps1`, ani
kvůli ověření jejich rozsahu.

1. Připni konfiguraci reference na commit SHA a zaznamenej instalovaný release.
   Z organizace platformy odvoď přesné tři názvy pomocí
   `Get-PlatformInstanceOrganization`. Název cílové organizace porovnej bez
   rozlišení velikosti písmen se všemi třemi; shoda pilot blokuje.
2. Ověř všechny organizační parametry a state roots. `organizations/main.tf`
   vytváří pouze organizace `actions` a `workloads`. Organization-scoped
   moduly validují přesnou množinu organizací instance; katalog akcí cílí do
   organizace akcí. Žádný target, identita objektu v uloženém state ani dříve
   zahájený krok nesmí odkazovat na organizaci pro vývoj platformy.
3. Pouze čtením zaznamenej state a bootstrap inventory v neveřejném úložišti,
   včetně jejich hashů a času čtení. Bootstrap removal odvozuje organizaci
   platformy z instance a deployment identifier a vyžaduje shodu inventory
   s jejím repozitářem `instance`. Ověř, že nejde o organizaci pro vývoj
   platformy ani její repozitář. Sdílené identity posuď odděleně podle
   následujícího kroku; jejich sdílení samo neporušuje organizační hranici.
4. Zkontroluj také ruční plán mazání. Smaže-li operátor všechny organizace
   enterprise místo přesných organizací instance, zdrojový scope ho neochrání.
   Důkaz musí výslovně vyloučit organizaci pro vývoj platformy, její repozitáře,
   issues, CI a přístup potřebný k jejich obnově.
5. Zapiš sdílené závislosti: enterprise Actions politiky, SSO/OIDC, SCIM,
   lifecycle EMU uživatelů a týmů, licence a enterprise-owned Apps.
   Vyloučení organizačních objektů neprokazuje nezávislost těchto závislostí.

Chybějící nebo nečitelný state, neznámý vlastník objektu a neověřený rozsah
zůstávají blokací A2. Neprovedený teardown se nesmí vykázat jako úspěšný
destruktivní test.

## Dopad sdílených změn a návrat

Zdrojová úprava host adaptéru sama nevyžaduje změnu enterprise, SSO ani SCIM.
Modul [`emu-identity`](../../modules/emu-identity/README.md) ale spravuje Entra
skupiny a app-role assignments, přes které SCIM zřizuje uživatele a jejich role.
Jejich odstranění může odebrat i přístup do organizace pro vývoj platformy,
přestože její GitHub objekty zůstanou zachované. Před potřebným zásahem
do těchto prostředků posuď konkrétní dopad a dolož ověřitelný plán návratu.
A3 nevyžaduje novou nezávislou identitu ani odolnost proti libovolnému
enterprise nebo Entra teardownu. Samotná sdílená závislost neblokuje pilot,
který ji nemění; neověřenou obnovu a odloženou destruktivní akceptaci však
zaznamenej odděleně jako neověřené. Tento runbook přiřazení ani zásah
nevytváří a nepovoluje.

Pokud se objeví potřeba sdílené změny, před zápisem vytvoř neveřejný záznam:

| Pole | Povinný obsah |
|---|---|
| Změna a souhlas | Přesný objekt, aktér, operace a konkrétní souhlas uživatele; nikoli souhlas odvozený ze spec. |
| Dopad | Dotčené přístupy do vývoje i reference, workflow, Apps, účty a obnova po odstranění `emu-identity`. Samostatná organizace není úplná izolace. |
| Výchozí stav | Úplný readback nastavení a jeho hash, nikoli jen zamýšlený rozdíl. Credentials do záznamu nepatří. |
| Návrat | Konkrétní původní hodnoty, pořadí obnovení, oprávněný vlastník a dostupná cesta obnovy nezávislá na měněné identitě. Změnu sdíleného IdP nebo enterprise nesmí převzít druhý nezávislý správce. |
| Ověření | Readback po změně i po návratu a ověření přístupu k vývoji a referenci. Při ztrátě odpovědi nejdřív přečti skutečný stav; zápis neopakuj naslepo. |
| Zastavení | Chybějící souhlas, nesoulad readbacku nebo nedostupný návrat zastaví pilot. Výsledek zůstane přerušený či neověřený. |

Při neúspěšném pilotu nepřepínej běžnou práci. Zachovej PR, head SHA,
výsledky a důvody selhání. Návrat přípravy může ponechat neaktivní pilot
a původní místo práce; smazání organizace či repozitáře není automatický
úklid. Každé odstranění a skutečné obnovení sdíleného nastavení vyžaduje
odpovídající souhlas.

## Živá akceptace a předání

Neveřejný receipt musí propojit source revizi, cílový PR, jeho head SHA,
konfiguraci pravidel, skutečné CI runs, review, JSON verdikt gate a
nedestruktivní důkaz hranice správy. U každého kritéria uveď
`ověřeno` s důkazem, `neověřeno` s chybějícím důkazem nebo `blocked`
s konkrétním předpokladem.

Ověř i odmítnutí neúplného gate: například read-only vyhodnocení téhož PR
s jiným `ExpectedHeadSha` musí vrátit `head-moved`, nikoli pass. Není nutné
zkoušet neautorizovaný zapisující požadavek ani měnit pravidla, aby vznikl
negativní důkaz. Přerušení nebo timeout kontroly nesmějí vytvořit úspěch.

A je přijatelný až s funkčním pilotem a splněnými A1 až A5.
Zdrojový PR bez těchto důkazů může předat pouze zdrojovou přípravu; nesmí
automaticky uzavřít ticket A ani odblokovat B. B a C zachovávají skutečné
závislosti a vlastní živé souhlasy. Předání source PR se řídí
[merge gate](../agents/repository-rules.md#merge-gate), nikoli tímto inventářem.

REST čtení používají `X-GitHub-Api-Version: 2026-03-10`; konkrétní operace
a odkazy na primární dokumentaci uvádějí hlavičky nástrojů. Tento runbook
nemění schema fixtures, required checks, oprávnění workflow ani standardní
release a zákaznický vendoring podle [ADR 0012](../adr/0012-public-source-repository.md).
