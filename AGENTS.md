# Agent instructions

## Agent skills

### Issue tracker

Issues are tracked in GitHub Issues for `msucharda/devsecops-platform` (via the `gh` CLI). See `docs/agents/issue-tracker.md`.

### Triage labels

Default canonical labels: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.

### Vývojový postup

Před návrhem nebo implementací načti [vývojový postup](docs/agents/development.md).
Skills jsou verzované v `.github/skills`. Implementaci zahajuje `/implement-spec`
přímo v aktuální session; nevyžaduje kickoff ani povinný custom agent profil.
Při volbě modelu nebo spouštění subagenta načti [model routing](docs/agents/model-routing.md).

## Coding standards

Pravidla platí pro implementaci i code review. Code review je ověřuje podle sekce [Code review](#code-review).

### Kontrakt externího API

- PR, který přidává volání externího API, musí citovat schéma z primární dokumentace: URL operace a verzi API. Pro GitHub REST je verze hodnota hlavičky `X-GitHub-Api-Version`, kterou nástroje posílají (`2026-03-10`).
- Kód musí zpracovat každou dokumentovanou variantu odpovědi (`oneOf`, `anyOf`), nebo nepodporovanou variantu odmítnout s jasnou chybou.
- Mocky a fixtures musí převzít tvar odpovědi z dokumentovaného schématu včetně variant. Tvar nesmí vzniknout odhadem ani z testovaného kódu.
- Pokud pozorované chování API neodpovídá dokumentaci, zapiš rozpor do PR jako nález s odkazem na důkaz. Produkční kód kvůli rozporu tiše neměň.
- Příklad, chyba A1 z experimentu #13: PR kontroloval vlastníka App přes `owner.type` a `owner.login`. Dokumentace `GET /app` definuje `owner` jako one-of Simple User (`login`, `type`) nebo Enterprise (`slug`, `id`, `name`, bez `login` a `type`). Ad hoc mock ve stejném chybném tvaru chybu zakryl.

#### Sdílené fixtures GitHub API

- Fixtures jsou v `tools/tests/fixtures/github-api/<kategorie>/<operace>[.<varianta>].json`. Jedna fixture obsahuje jeden tvar odpovědi.
- GraphQL fixtures jsou v kategorii `graphql/`. Zdrojem schématu je GraphQL SDL připnuté na commit (`github/docs`, `src/graphql/data/ghec/schema.docs.graphql`).
- Fixture má tři části:
  - `source`: `operation`, `operationId`, `documentation` (URL), `apiVersion`, `description` (OpenAPI popis z `github/rest-api-description` připnutý na commit), `status`, `schema`, volitelně `variant` a `note`.
  - `required`: cesta v těle odpovědi a seznam povinných polí podle schématu.
  - `body`: příklad odpovědi z dokumentace.
- Testy čtou fixture přes `Get-GitHubApiFixture -Name <název> -Set @{ '<cesta>' = <hodnota> }` z `tools/tests/GitHubApiFixture.psm1`. Parametr `-Set` mění jen pole, které fixture obsahuje.
- `tools/tests/GitHubApiFixture.Tests.ps1` ověřuje zdrojovou anotaci a povinná pole každé fixture.
- Tvar odpovědi GitHub API, který používá víc testů, musí mít sdílenou fixture. Ad hoc tvar může test použít jen pro jednorázovou odpověď nebo pro záměrně nevalidní vstup. Záměrně nevalidní vstup musí test označit komentářem.

### Testy bezpečnostních a identitních kontrol

Pravidla se týkají kontrol vlastníka, instalace, oprávnění, hranic a výsledku operace.

- Pozitivní test: každá dokumentovaná varianta platného vstupu (každá větev one-of) musí mít test. Test musí vycházet ze sdílené kontraktní fixture.
- Negativní test: každá podmínka kontroly musí mít vlastní test. Vstupem je platný vstup se změnou jediného pole: jiné ID, slug nebo typ, jiná velikost písmen, prázdná hodnota, chybějící pole, nadbytečný záznam. Test musí ověřit, že kontrola selže právě na testované podmínce, například podle chybové zprávy.
- Kontrola musí selhat bezpečně (fail-closed). Prázdný, neznámý nebo nečitelný stav nesmí projít jako úspěch.
- Příklady fail-open nálezů z Copilot code review:
  - #35: kontrola ručně zadaného App ID neověřila `slug`.
  - #40: `.github` se porovnávalo s rozlišením velikosti písmen.
  - #48: prázdný status prošel jako `Success`.
  - #27: kontrola přijala podmíněné ABAC přiřazení jako plné.
  - #43: kontrola porovnala marker jen jako podmnožinu.
  - A1 z experimentu #13: chyběl pozitivní test pro dokumentovanou variantu Enterprise.

### Obnova po přerušení

Pravidla se týkají každé operace, která mění stav: volání externího API, inventory, uložený progress, artefakty. Implementace i review musí pro každou dvojici kroků odpovědět na otázku: „Co se stane, když běh skončí mezi krokem X a Y?“

- Záměr ulož před vzdáleným zápisem. Pokud se ztratí odpověď na požadavek, další běh musí stav obnovit. Příklad #43: `initializationPending` se před vytvořením repozitáře změnil jen v paměti.
- Při výměně objektu (organizace, instalace) smaž výsledky vázané na původní objekt a změnu ulož. Příklad #48: náhradní organizace držela výsledky probe a `adminInstallationId` smazané organizace.
- Stav čti z pevné revize (SHA), ne z pohyblivého ref. Před akcí ověř, že se ref nezměnil. Příklad #43: marker a konfigurace se četly přes `ref=main`.
- Vyčištění musí proběhnout před každým místem, kde může běh selhat. Příklad #26: zastaralý artefakt se mazal až po načtení grafu, validaci a výběru, a proto přežil výjimku.
- Při obnově přerušeného běhu (resume) vyřeš čekající kroky před prvním čtením, které na nich závisí. Příklad #34: obnovený běh řešil čekající SAML sign-in (`organizationSignInPending`) až po org-scoped probe, a proto nejdřív dostal 403.
- Každá taková operace musí mít regresní test, který simuluje přerušení mezi kroky.

### Mechanické kontroly v CI

CI workflow `Source CI` běží s oprávněním `contents: read`. Pester, harness přerušení a mutační testy běží offline proti stubům.

#### Pester a závislosti jobů

- Job `Pester (<index>/4)` rozděluje soubory testů přes `tools/Invoke-Tests.ps1 -CI -Shard <index>/4`. Každý soubor připadne právě jednomu shardu. Tagy a explicitní `-Path` fungují stejně jako bez shardování.
- Odhady v `tools/pester-durations.psd1` vyvažují délku běhu. Nové soubory se zařadí automaticky s odhadem 1 s; po změně délky testů aktualizuj odhady podle časů souborů v XML artefaktech `pester-results-<index>`.
- Stabilní check `Platform tools` agreguje výsledky `Platform static checks`, všech shardů Pesteru a jobu `Discover Terraform roots`. Selhání, přeskočení nebo zrušení závislosti znamená selhání agregátu. Názvy `Source CI` a `Platform tools` zachovávají kompatibilitu merge gate a případných required checks.
- Joby `Terraform (<root>)` čekají jen na `Discover Terraform roots`, nikoli na Pester. Harness přerušení a mutační testy mají vlastní joby popsané níže.
- Lokální běh bez `-Shard` zachovává celou vybranou sadu. Pro reprodukci jednoho shardu použij například `./tools/Invoke-Tests.ps1 -CI -Shard 0/4`.

#### Harness přerušení

- Job `Interruption harness` spouští testy s tagem `Interruption` ve 4 shardech (`INTERRUPTION_SHARD=<index>/4`). `tools/Invoke-Tests.ps1` bez parametru `-Tag` tyto testy vynechá. Lokální běh: `./tools/Invoke-Tests.ps1 -Tag Interruption`.
- Harness je v `tools/tests/InterruptionHarness.psm1`. `Invoke-InterruptionMatrix` spustí nástroj jednou a spočítá zapisující kroky. Pak pro každý krok spustí dvě varianty: `BeforeApply` (požadavek selže před zápisem) a `LoseResponse` (stub zápis provede a odpověď se ztratí). Každou variantu ukončí dvěma způsoby:
  - `Error`: stub vrátí chybovou odpověď a v nástroji proběhnou bloky `catch` a `finally`.
  - `Abrupt`: proces skončí přímo na hranici přerušení. Harness vrátí lokální stav, který zachytil na hranici, a zahodí zápisy z `catch` a `finally`. Stav stubu zůstane.

  Po každém přerušení harness spustí nástroj znovu a vyžaduje:
  - opakovaný běh skončí úspěchem;
  - snapshot stavu stubu a lokálního stavu se rovná referenčnímu běhu;
  - žádné vytvoření objektu neproběhlo víckrát než v referenčním běhu.
- Nový nástroj, který mění stav, zapoj do harnessu takto:
  1. Ve stubu API pošli každý zapisující požadavek přes `Invoke-InterruptionStep`. U vytvoření, které API při opakování neodmítne, předej `-Identity`.
  2. Napiš `Reset` (počáteční stav stubu a lokálních souborů), `Run` a `Snapshot`. `Snapshot` vynechá hodnoty, které se mezi běhy legitimně liší (generovaná ID, časy). Napiš `CaptureLocal` (vrátí uložený lokální stav, například text stavového souboru) a `RestoreLocal` (zapíše zachycený stav zpět).
  3. Přidej `Describe` s tagem `Interruption` a sharduj přes `Get-InterruptionShard`. Vzor: `tools/tests/GitHubBootstrap.Interruption.Tests.ps1`.

#### Mutační testy bezpečnostních kontrol

- Job `Security check mutation tests` spouští `tools/Invoke-MutationTests.ps1`. Skript oslabí každou označenou kontrolu a vyžaduje, aby pro každého mutanta selhal aspoň jeden test.
- Mutanti (mutants):
  - podmínka guardu s `throw`, `return $false`, `Write-Error`, `Exit-SetupStage` nebo výstupem textového literálu důvodu (kontrola, která vrací seznam důvodů zamítnutí) se změní na `$false` a na negaci;
  - podmínka s `continue` nebo `return $true` a logický `return` se změní na `$true` a na negaci;
  - každý operand `-or` v zamítací podmínce se změní na `$false`, každý operand `-and` v povolovací podmínce na `$true`;
  - case-sensitive operátor (`-ceq`, `-cne`, `-clike` a další) se změní na case-insensitive, pokud tím kontrola přijme víc hodnot.
- Novou bezpečnostní nebo identitní kontrolu označ takto:
  1. Na řádek přímo před funkci kontroly napiš `# security-check: <name>`. Název je kebab-case a je unikátní. Skript hledá markery ve skriptech v `tools/` a `modules/` mimo adresáře `tests/`.
  2. Do `tools/tests/security-checks.psd1` přidej položku `Checks` s názvem a testy (`Path` a filtr `FullName`). Filtr porovnává nerozbalený název testu, tedy včetně `<Case>`.
  3. Lokálně spusť `./tools/Invoke-MutationTests.ps1 -Check <name>`.
- Přeživší mutant (survived) je chybějící negativní test. Doplň test. Výjimku v `Exceptions` přidej jen pro ekvivalentního mutanta, který nemůže změnit chování. Výjimka musí mít přesné ID mutanta z reportu, důvod a URL issue nebo PR.
- Běh selže při nesouladu markerů a konfigurace, při chybě baseline, při chybě mutanta, při přeživším mutantovi bez výjimky a při zastaralé výjimce.
- Generovaný teardown YAML pokrývá explicitní adaptér `TeardownWorkflow` v mutační konfiguraci. Mění predikáty přes šablony generátoru a používá stávající worker a kontraktní testy bez produkčního markeru. Testy adaptéru musí doložit změnu emitované podmínky, platný YAML a odmítnutí kontraktní assertion; chyba generátoru ani runneru není zabitý mutant.

### Lokální validace

Před spuštěním testů (včetně cíleného TDD), lokálního gate nebo pushem a při změně či review runneru načti
[pravidla lokálního CI](docs/agents/local-ci.md). Před každým pushem musí projít
commit-bound gate; před merge úplné Linux Source CI na přesném head SHA.
Podrobný postup, výsledky, cache, rozpočty a pravidla bezpečného TEMP mají jediný
zdroj v odkazovaném dokumentu.

### Security checkpoint během implementace

Spouštěč: návrh bezpečnostní nebo identitní kontroly je hotový včetně testů, celá změna ještě ne. Checkpoint se týká validace vlastníka, instalace, oprávnění, hranic, revokace tokenu a mazání. Netýká se dokumentace ani refaktoringu beze změny chování.

- Implementátor použije skill `security-checkpoint`. Reviewer musí mít čerstvý kontext a jinou modelovou rodinu podle [model routingu](docs/agents/model-routing.md); modely se zde neduplikují.
- Reviewer dostane jen diff, zadání a odkazy na primární dokumentaci API. Zdůvodnění ani poznámky implementátora nedostane.
- Reviewer ověří jen tři oblasti: tvar externího API proti dokumentaci, fail-open stavy a obnovu po přerušení podle pravidel výše.
- Implementátor nálezy opraví hned. Koncové code review a Copilot review v PR zůstávají beze změny.
- Důvod: v experimentu #13 interní review ve stejném modelu a kontextu nenašlo nic. Nezávislé slepé review našlo vysokou chybu A1.

### Code review

Skill `code-review` čte tato pravidla jako coding standards repozitáře. Osa Spec musí navíc provést tři kroky:

1. Ověřit každý mock a každou fixture externího API proti primární dokumentaci (URL a verze API citované v PR), včetně všech variant `oneOf` a `anyOf`. Mock odvozený z testovaného kódu je nález.
2. U bezpečnostní nebo identitní kontroly ověřit pozitivní test pro každou variantu, negativní test pro každou podmínku a fail-closed chování.
3. U každé operace, která mění stav, odpovědět na otázku „Co se stane, když běh skončí mezi krokem X a Y?“ a ověřit regresní test přerušení.

## Práce agentů

Pravidla platí pro každého agenta v repozitáři.

### Vlastnictví práce a delegování

- Výchozí režim je přímá práce aktuální session. Jedna dodávka má jednoho vlastníka implementace, integrace, závěrečného review, validace a handoffu.
- Ticket určuje výsledek a akceptační kritéria, ne počet agentů, sessions ani PR. Nová child session vzniká kvůli izolované větvi nebo samostatnému životnímu cyklu, ne automaticky pro další krok.
- Subagent dostane ohraničený výsledek, potřebné zdroje a podmínku ukončení. Zadavatel stejnou práci souběžně neopakuje. Krátké lookupy a jeden souvislý průchod kódem řeší přímo.
- Paralelní implementace vyžaduje výslovný souhlas uživatele; počáteční limit jsou dva souběžní implementátoři. Delegovaný implementer nerozděluje implementaci dalším implementerům. Povinné nezávislé review a security checkpoint zůstávají.
- Předání používá odkazy na zdroje a stručné nové informace, ne kopii celé spec nebo obecných pravidel. Vlastníkem závěrečného procesu zůstává jedna session; běžná integrace ani opravy nepotřebují dalšího agenta.
- Retrospektiva ani retrospektivní subagent nejsou podmínkou dokončení. Dřívější rozhodnutí zrušil [PR #248](https://github.com/msucharda/devsecops-platform/pull/248).

### Čekání a blokace

- Stav `hotovo` vyžaduje všechny předepsané výsledky. Stav `blocked` umožňuje pozastavit práci při externí závislosti, běžící CI, nedostupné službě nebo vyčerpaném schváleném rozpočtu; neznamená úspěch.
- Při pozastavení uveď přesný blocker, poslední ověřené SHA, rozpracované změny a podmínku obnovení. Sledování stejného stavu má jednoho vlastníka.
- Použij dostupnou notifikaci nebo ne-modelový monitor. Pokud je nutná jednorázová kontrola, použij `tools/Wait-PullRequestChecks.ps1`. Při nezměněném čekajícím stavu ukonči tah; nevytvářej další modelové tahy jen kvůli polling smyčce.
- Není-li dostupné probuzení, výslovně uveď, kdo a jak může práci obnovit. Neslibuj automatické pokračování bez skutečného mechanismu.
- Pokyn STOP ruší dosavadní plán pokračování. Zastav vlastní práci i delegované úlohy, zachovej změny a obnov práci až po novém výslovném pokynu uživatele.

### Fakta a rozhodnutí

- Každý fakt o stavu musí mít označení: ověřený (čím), nahlášený (kým), nebo neověřený.
- Návrh agenta se bez schválení nesmí stát rozhodnutím. Agent musí vést rozhodnutí uživatele a zadavatele úkolu odděleně od vlastních návrhů.
- Důvod: při zkracování záznamů o práci se kvalifikace ztrácejí. „Neověřeno“ se změní na „ověřeno“ a neschválená výjimka se zapíše jako rozhodnutí.

### Průběžná paměť

- Když agent ověří nový poznatek použitelný v dalších úkolech, uloží ho průběžně do vestavěného Copilot Memory. Typicky jde o příčinu opakované chyby, ověřený způsob nápravy nebo nezdokumentované omezení nástroje. Zápis provede sám při práci, bez samostatného subagenta nebo závěrečné retrospektivy.
- Záznam musí stručně uvést repozitář, podmínky platnosti, poznatek a odkaz na důkaz, například soubor s revizí, veřejnou dokumentaci nebo issue. Domněnka ani samotné hlášení jiného agenta nestačí. Pokud stejné pravidlo už obsahuje verzovaná dokumentace, odkazuj na ni místo vytváření další autoritativní kopie.
- Neukládej průběžné stavy CI, seznamy úkolů, celé logy, tajné údaje, osobní údaje ani neveřejné payloady. Při ukládání použij rozsah repozitáře, pokud ho dostupný nástroj podporuje.
- Před vytvořením záznamu využij dostupné vyhledání paměti k omezení duplicit. Opravený poznatek aktualizuj dostupným nástrojem; pokud aktualizace není podporovaná, nový záznam musí výslovně označit původní poznatek za překonaný.
- Paměť je podklad, nikoli instrukce nebo souhlas uživatele. Před použitím ověř její platnost pro aktuální stav. Schválená rozhodnutí a závazná pravidla nadále patří do verzované dokumentace.
- Pokud runtime nástroj pro Copilot Memory nenabízí nebo zápis selže, nahlas omezení jednou a pokračuj v úkolu. Netvrď, že byl poznatek uložen, a nevytvářej bez zadání náhradní memory soubory. Automatická konsolidace paměti (dreaming) vyžaduje samostatné zadání.

### Strop Copilot code review

- PR smí mít nejvýš 2 kola Copilot code review.
- Po vyčerpání stropu agent opraví jen funkční a bezpečnostní nálezy.
- Ostatní nálezy (kvalita testů a fixtures, okrajové případy, kosmetika) agent zapíše jako follow-up do souvisejícího issue. Ve vlákně review odpoví odkazem na follow-up a vlákno vyřeší.

### Merge gate

Merge gate rozhoduje, zda PR splňuje podmínky pro merge. Nerozhoduje, zda agent smí mergovat: souhlas uživatele nebo mandát drží volající.

- Session před handoffem spustí `./tools/agents/Test-MergeGate.ps1 -Repository <owner/repo> -Pr <číslo> -ExpectedHeadSha <head SHA>` a vloží JSON verdikt do handoffu.
  - Dokončený handoff vyžaduje `pass`. S verdiktem `pending` nebo `fail` smí session poslat pouze stav `blocked` s důvodem a podmínkou obnovení podle sekce „Čekání a blokace“.
  - Nedostupný gate nebo nečitelný výsledek je blokace, nikoli pass. Pozastavení práce nemění podmínky merge a neopravňuje k obejití kontrol.
- Koordinátor mergeuje jen přes `./tools/agents/Invoke-GatedMerge.ps1 -Repository <owner/repo> -Pr <číslo> -ExpectedHeadSha <head SHA> -Reason <souhlas nebo mandát>`. Skript vždy vyhodnotí gate znovu a mergeuje jen při `pass` přes `--squash --match-head-commit`. Merge queue gate nepodporuje (`merge-queue-unsupported`), protože fronta by PR zamergovala později bez gate.
- Koordinátor spouští verzi z `origin/main`, aby větev nemohla oslabit vlastní gate. Do důvěryhodného dočasného adresáře rozbalí celé `tools/` z této revize (`git archive origin/main tools | tar -xf - -C <adresář>`), včetně přibaleného YAML parseru a jeho hashů. Samostatná kopie skriptů z `tools/agents/` tento runtime neobsahuje. Závislosti nesmí načítat z větve PR.
- Agent nesmí použít `gh pr merge --admin`, `--auto` ani `gh pr ready` a merge v jednom kroku. Verdikt `blocked-by-rules` znamená chybu v rulesetu, ne důvod k obejití pravidel.
- Změnu oprávnění tokenu (`permissions`), všech triggerů (`on`, události a jejich filtry), secrets (včetně `GITHUB_TOKEN` a `github.token`) nebo všech runnerů (`runs-on`, včetně GitHub-hosted) v `.github/workflows/**` nebo `.github/actions/**` musí potvrdit člověk pro konkrétní head SHA. G10 porovnává strukturu YAML z pevných merge-base a head SHA, nikoli řádky patche. Nečitelný obsah, neplatný YAML a nepodporované anchors nebo aliasy vedou k `workflow-permissions-changed`. Koordinátor potvrzení předá přes `-AcknowledgeWorkflowChanges <head SHA>`.
- G10 určuje úplnou množinu cest a statusy změn porovnáním Git trees z pevných merge-base a head commit SHA. Merge base přebírá jen z compare pevných base-tip/head SHA; chybějící nebo neplatné SHA a status mimo `ahead`, `identical`, `diverged` vedou k `evaluation-error`. Finální kontrola base tipu a head zůstává. `pulls/files` slouží jen jako doplňkový signál dostupnosti a úplnosti; neurčuje statusy ani párování rename/copy. Benigní přesun mezi přímými workflow cestami odvozuje G10 deterministicky shodou citlivé YAML projekce. Přímá workflow cesta musí přesně odpovídat `.github/workflows/<soubor>.yml` nebo `.yaml`, včetně velikosti písmen a konce řetězce. Ostatní cesty zůstávají added, removed nebo modified. Chybějící nebo zkrácený strom a limit API vedou k `evaluation-error`, nikoli k přijetí částečného seznamu. Rekurzivní Git trees API má limit 100 000 položek nebo 7 MB; velký repozitář proto může gate odmítnout i při malém PR.
- Rozhodnutí koordinátora pro #141 z 28. 10. 2026: kopie platného workflow vyžaduje potvrzení, protože přidává citlivé nastavení `on`. Kopii local action posuzuje G10 stejně jako přidanou local action: s citlivým nastavením vyžaduje potvrzení, s prázdnou citlivou projekcí projde. Samotný status `copied` z `pulls/files` nesmí verdict změnit.
- Rename výjimka G10 platí jen pro zdroj, který na pevném base tipu zůstává přímým regular workflow se stejnou citlivou projekcí jako cíl. Base-tip strom G10 čte jen při kandidátech přesunu a rozdílném merge-base SHA. Symlink, submodule nebo náhrada souboru za adresář v citlivé cestě dostane `gateSnapshotError`, zůstává mimo párování rename a vyžaduje potvrzení pro konkrétní head. Neplatný nebo neúplný strom vede k `evaluation-error`; potvrzení ho neobejde.
- Rozhodnutí koordinátora z 28. 10. 2026: obsahuje-li některé z uvedených citlivých polí v base nebo head výraz `${{ ... }}`, jakákoli změna souboru vede k `workflow-permissions-changed`. G10 výrazy nevyhodnocuje ani nerozlišuje jejich závislosti (`matrix`, `needs.*.outputs`). Hodnotu `self-hosted` hlídá i mimo klíč `runs-on`.
- G4 páruje required status check podle `context` a případného `integration_id`. S `integration_id` ho splní jen check run se stejným `app.id`; commit status nestačí. Bez `integration_id` stačí shodné jméno.
- Konvence těla PR:
  - Tělo PR musí vždy obsahovat sekci `## Otevřené otázky`. Bez otázek obsahuje text „Žádné“. Neprázdná sekce zastaví merge (`open-questions`).
  - Sekce `## Otevřená živá kritéria` není otevřená otázka a gate ji nečte.
  - Sekce `## Rozhodnutí uživatele` (nebo `## Rozhodnutí pro uživatele`) bez ověřeného markeru přijetí vede k varování `decisions-unconfirmed`. Marker má tvar `<!-- merge-gate: decisions-accepted <login> <YYYY-MM-DD> -->`. G9 ověří login autora PR a všech editorů úplné neredigované historie těla proti loginu markeru. Nečitelná nebo nedočtená historie a jiný editor ponechají varování. Platí to i pro koordinátora; samostatný mandát nenahrazuje důkaz. Tento konzervativní důkaz odmítne i marker vložený uvedeným loginem po editaci jiného účtu.

## Jazyk

- Dokumentace, ADR, specifikace modulů a issues jsou česky podle skillu `controlled-czech`.
- Termíny jsou anglicky podle glosáře v `CONTEXT.md`. Český ekvivalent je v závorce u termínu.
- Kód, komentáře v kódu, názvy workflow a commit messages jsou anglicky.
