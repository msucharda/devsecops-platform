# Destilace retrospektiv

Tento postup zavádí [ADR 0019](../../adr/0019-session-retrospectives-enforced-by-merge-gate.md) a #228. Není pravidlem odvozeným z opakovaných nálezů. Denní app-local automation spouští agenta [retro-distiller](../../../.github/agents/retro-distiller.agent.md) s modelem `claude-opus-5.5` a reasoning `xhigh`. Konkrétní čas a aktivaci automation potvrzuje její správce v aplikaci; Git tyto údaje nespravuje.

## Vstupy a povýšení

- Formát vstupu určuje [README retrospektiv](../retros/README.md). Agent zpracuje alespoň tři platné nezpracované retrospektivy z jednoho pevného SHA `origin/main`. Neplatný vstup blokuje dávku; agent ho zachová a nahlásí.
- Nezávislý výskyt znamená jiné pole `session`. Více záznamů z jedné session nezvyšuje počet. Agent identifikuje stejnou příčinu a stejnou nápravu, nikoli jen podobný text.
- Dva nezávislé výskyty dovolují návrh pravidla. Jednorázový bezpečnostní nález nebo nález s vysokou cenou vyžaduje doložený dopad a zdůvodnění výjimky v PR. ADR neurčuje číselný práh vysoké ceny. Bez doloženého zdůvodnění zůstává nález kandidátem.
- Pravidlo zůstává návrhem až do review a merge uživatelem. Rozpor s `AGENTS.md`, ADR či průvodcem patří do `## Otevřené otázky` v PR; agent původní pravidlo zachová.

## Tematický průvodce a kandidáti

Tematický soubor `docs/agents/guide/<téma>.md` má kebab-case název. Každé pravidlo musí uvést situaci, konkrétní krok, důvod, počet nezávislých session a zdroje. Výjimka pro jeden výskyt musí navíc uvést bezpečnostní dopad nebo doloženou vysokou cenu. Index v `AGENTS.md` má jeden řádek na téma s podmínkou čtení. Agent přidává odkazy, nikoli pravidla do jiných sekcí `AGENTS.md`.

Soubor `docs/agents/retros/candidates.md` obsahuje sekci pro každou příčinu. Sekce musí mít:

- návrh pravidla a důvod, proč zatím nepostoupil;
- počet nezávislých session;
- seznam zdrojů: ID session, ID nálezu, celé zdrojové SHA a odkaz;
- označení ověřeného, nahlášeného či neověřeného stavu důkazu;
- případný rozpor s přesným odkazem na stávající pravidlo.

Agent sjednocuje nové a historické zdroje podle dvojice session a ID nálezu. Počet počítá podle různých session. Po povýšení přenese celou evidenci ke konkrétnímu pravidlu a odstraní kandidáta; ostatní kandidáty zachová. Dva doklady ze stejné session nikdy nevytvoří dvě nezávislé session.

Odkaz na zdroj má tvar `https://github.com/msucharda/devsecops-platform/blob/<plné-SHA>/docs/agents/retros/<soubor>.md#r1-<kotva>`. Celé SHA je povinné; odkaz přes `main` po smazání vstupů přestane fungovat. Obsah i zdroje musí splňovat pravidla veřejného repozitáře z README retrospektiv.

## Publikační helper a obnova

Veřejný vstup `tools/agents/Invoke-RetroDistillation.ps1` podporuje tři režimy:

| Režim | Výsledek |
|---|---|
| `Inspect` | Read-only inventář PR a větví; Git fetch aktualizuje objekty a remote-tracking ref, nikoli checkout. `NoOp` při otevřeném PR nebo méně než třech názvech vstupů, `Prepare` pro novou dávku, `Resume` pro jedinou čekající větev. Validaci obsahu dělá agent. |
| `Commit -SourceSha <SHA> -BodyPath <soubor>` | Jeden commit přímo nad zdrojovým SHA; obsah a tělo PR uloží před push. Tělo PR patří do ignorovaného `artifacts/retro-distillation/`, nikoli mezi vstupy. |
| `Publish` | Vyžaduje čistý checkout a platný lokální gate pro head a zdrojové SHA. Objeví stav znovu, vytvoří chybějící větev a PR, nebo vrátí `NoOp`. |

Identita větve je `retro-distillation/<plné-zdrojové-SHA>`. Pushed commit je checkpoint: má právě jednoho parenta rovného zdrojovému SHA a jeden trailer `Retro-Body` s Base64 UTF-8 tělem PR. Base64 není šifrování; tělo smí obsahovat jen veřejné údaje. Helper ověřuje povolené cesty, regular soubory, zachování `AGENTS.md` mimo index a smazání alespoň tří vstupů.

Identitu dávky určuje množina cest všech vstupních retrospektiv z pevného zdrojového SHA. Helper seřadí cesty ordinálně, spojí je znakem LF bez koncového LF a spočítá SHA-256 z UTF-8. Režim `Commit` doplní do těla PR marker `<!-- distillation-batch: sha256:<64 malých hexadecimálních znaků> -->` a ověří shodu se skutečně smazanými cestami. Marker uloží do checkpointu před push. Existující marker musí být právě jeden, kanonický a odpovídat dávce.

**Rozhodnutí uživatele pro #239, varianta B:** zavřené PR bez merge blokuje pouze tutéž množinu vstupních souborů. Přidání nebo odebrání retrospektivy dovoluje novou dávku; změna zdrojového SHA, obsahu nebo pořadí stejných cest identitu nemění. Otevřené destilační PR vždy ukončí běh bez změn. Chybějící, nečitelný nebo nejednoznačný marker zavřeného PR bez merge blokuje běh pro rozhodnutí uživatele; helper identitu neodhaduje z názvu větve. Platně sloučená historie další dávku neblokuje.

| Hranice přerušení | Další běh |
|---|---|
| Před commitem, včetně přerušení mezi mazáním retrospektiv, nebo před push | Vzdálený checkpoint neexistuje; další automation běží v novém izolovaném worktree a znovu připraví dávku z aktuálního pevného SHA. Při ruční obnově stejného worktree agent znovu přečte úplný inventář a obsah z původního zdrojového SHA, nikoli jen dosud nesmazané soubory. |
| Po push, před vytvořením PR; i při ztrátě odpovědi na push | Inventář najde čekající větev před volbou nové dávky. Agent použije její commit a uložené tělo PR bez nové destilace. |
| Po vytvoření PR; i při ztrátě odpovědi na vytvoření | Inventář najde otevřené PR a skončí bez změny. |
| Souběžná změna větve nebo více čekajících větví | Helper změnu odmítne. Agent zachová checkpoint a nahlásí blokující stav. |
| Posun main pouze mimo `AGENTS.md`, `docs/agents/` a `docs/adr/` | Obnova použije původní checkpoint a původní SHA; gate se spustí nad tímto SHA. |
| Posun main uvnitř těchto vstupů nebo neznámý stav | Agent zachová checkpoint pro rozhodnutí uživatele; nevytváří náhradní větev. |
| Zavřené PR bez merge se shodnou identitou dávky | Helper blokuje opakování téže dávky. Jiná množina vstupních souborů může pokračovat do nového PR. |
| Zavřené PR bez merge bez jednoznačné identity dávky | Helper blokuje běh; uživatel musí nejprve vyřešit identitu historického PR. |

Helper stránkuje GitHub REST přes `gh api --paginate --slurp`. Používá operace [list pull requests](https://docs.github.com/en/enterprise-cloud@latest/rest/pulls/pulls#list-pull-requests) a [create a pull request](https://docs.github.com/en/enterprise-cloud@latest/rest/pulls/pulls#create-a-pull-request), verzi API `2026-03-10`. Nullable autor seznamu není chyba ani důkaz typu session. Helper nevyžaduje autora typu Bot.

Fetch i push URL `origin` musí mířit na `msucharda/devsecops-platform` na `github.com`, shodně s REST cílem. Helper podporuje HTTPS a SSH (`git@github.com:…`, `ssh://git@github.com/…`); jiné hosty, forky a více URL odmítne před výběrem dávky. Pole `head.repo` a `base.repo` musí odpovídat nenullovatelnému schématu. Nullable `body` ani nullable `user` seznamu samy o sobě identitu PR nemění.

Automation musí používat `workspace_type: worktree`: každý běh začíná novou session s izolovaným checkoutem. Původní nedokončený worktree zůstává zachovaný. Při ručním pokračování ve stejném worktree lze zopakovat `Commit` se stejným `SourceSha` a souborem těla PR. Helper dokončí rozpracovaný index; pokud commit již existuje, ověří jeho identitu a vrátí jej bez druhého commitu. Nesouvisející změny ani index nemaže.

## Offline ukázka a stav ověření

`tools/tests/fixtures/retro-distillation/` obsahuje tři výslovně syntetické retrospektivy. Integrační scénář používá skutečný izolovaný Git a bare remote; GitHub nahrazuje sdílenými kontraktními fixtures `pulls/list` a `pulls/create`. Předem připravený výstup ukazuje pravidlo se dvěma session a kandidáta s jednou session. Fixture výstup nenahrazuje skutečnou destilaci modelem.

Izolovaná unit sada ověřuje stejné veřejné příkazy se stuby procesových hranic Git, GitHub CLI a lokálního gate. Mutační runner používá tuto rychlou sadu. Skutečné chování Gitu a vzdálenou obnovu nadále ověřují integrační scénář a harness.

```powershell
./tools/Invoke-Tests.ps1 -Path ./tools/tests/RetroDistillation.Tests.ps1
./tools/Invoke-Tests.ps1 -Path ./tools/tests/RetroDistillation.Unit.Tests.ps1
./tools/Invoke-Tests.ps1 -Path ./tools/tests/RetroDistillation.Contract.Tests.ps1
./tools/Invoke-Tests.ps1 -Path ./tools/tests/RetroDistillation.Interruption.Tests.ps1 -Tag Interruption
```

Harness ověřuje přerušení před zápisem a ztrátu odpovědi pro smazání každé vstupní retrospektivy, push i vytvoření PR, včetně ukončení `Error` a `Abrupt`. Každý další běh musí zachovat zdroj každého nálezu a dosáhnout stejného vzdáleného výstupu bez duplicitní větve či PR. Lokální gate v izolované fixture nahrazuje skript s exit code; skutečný gate se spouští samostatně nad implementací.

**Neověřeno touto ukázkou:** významová destilace modelem, skutečné GitHub PR nad alespoň třemi reálnými retrospektivami, aktivace app-local automation a skutečné spuštění profile z této automation. Fixtures se nesmí vydávat za skutečné retrospektivy ani kopírovat do produkčního `docs/agents/retros/`.
