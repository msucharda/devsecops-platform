# Agent instructions

## Agent skills

### Issue tracker

Issues are tracked in GitHub Issues for `msucharda/devsecops-platform` (via the `gh` CLI). See `docs/agents/issue-tracker.md`.

### Triage labels

Default canonical labels: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.

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

### Lokální validace

Před pushem musí projít rychlý lokální gate. Před merge musí projít úplné Linux Source CI na přesném head SHA PR.

- Před každým pushem spusť `./tools/Invoke-LocalCi.ps1` (výchozí režim `-Changed`). Platí to i pro změny jen v dokumentaci. Push je povolený jen po návratovém kódu 0.
  - `-Changed` analyzuje změněné PowerShell soubory, ověří manifesty a generované workflow a spustí dotčené izolované unit a contract suites. Kategorie určuje `tools/test-profiles.psd1`; nový test musí mít právě jednu kategorii.
  - `-Plan` vypíše lokální výběr i soubory ponechané vzdálenému CI. Terraform, integration suites, harness přerušení a mutace zůstávají v úplném profilu. Změna runneru lokálně vybere izolované suites, nikoli celou těžkou sadu.
  - Cíl je 5 minut, nikoli timeout měnící nedokončený běh na úspěch. Pass znamená jen „vybraný lokální gate prošel“.
  - Návratový kód 2 znamená chybějící nástroj, špatnou verzi modulu nebo chybný parametr. Skript vypíše instrukci k opravě.
- Commit vytvoř před gate. Výsledek platí jen pro stejný HEAD, base SHA a obsah všech sledovaných i neignorovaných nových souborů. Gate odmítne index s `assume-unchanged` nebo `skip-worktree` (včetně sparse-checkout), protože tyto příznaky skrývají změny před kontrolou čistoty. Před pushem ho ověř přes `tools/Test-LocalCiResult.ps1`. Push prováděj přes `git -c core.hooksPath=.githooks push`, aby pre-push hook ověřil i skutečně odesílaný commit. Po změně kódu nebo commitu gate zopakuj.
- `-Base` má výchozí hodnotu `origin/main`; u stacked PR použij jeho base branch. Runner pracuje offline s místními refs; jejich aktualizaci proveď před gate. Ověření výsledku převezme base z uloženého pass.
- Plnou sadu spouští Linux CI beze změny kategorií či počtu původních případů. `-Full` je dostupný lokálně na výslovné vyžádání, nikoli jako automatická eskalace rychlého gate. Chybějící, neúplný, zastaralý nebo nedostupný vzdálený výsledek blokuje merge; úspěšný lokální gate dovoluje push i při výpadku CI.
- Lokální běhy drží worktree zámek a sdílejí jednu strojovou FIFO frontu. Konfigurovatelný `-WorkerBudget` se ukládá pro celý stroj; výchozí rozpočet je 4. Těžké child procesy musí respektovat `LOCAL_CI_WORKER_BUDGET`. `-QueueWaitSeconds` omezuje čekání chybou, nikoli úspěchem. Plán zámky nebere.
- Na Windows běží gate ve vlastním PowerShell procesu s process-lifetime jobem; ukončení workeru ukončí i jeho potomky. Na Linuxu potomci dědí zámky, takže po přerušení runneru nový běh čeká na jejich konec. Další běh nesmí vyčistit jejich TEMP ani překročit rozpočet souběhu. Integrace mutačního runneru s `LOCAL_CI_WORKER_BUDGET` v `-Full` závisí na #107; samotný export proměnné její dodržení neprokazuje.
- Na Windows runner používá krátký soukromý TEMP mimo checkout (výchozí kořen `<UserProfile>\.dci`). `-TempRoot` smí být pouze přímý podadresář `UserProfile`; jiné umístění včetně `C:\t`, kořene svazku a cesty přes mezilehlou junction runner odmítne. Mimo Windows není `-TempRoot` podporovaný; ponech výchozí soukromý datový adresář. Výsledná Windows cesta smí mít nejvýš 64 znaků. Nové adresáře vzniknou s chráněným ACL jen pro aktuálního uživatele a SYSTEM. Existující kořen, mezisložka `devsecops-local-ci` i worktree adresář musí mít stejné omezení; runner cizí vlastnictví, širší ACL ani reparse point neopravuje, ale odmítne. Lokální Windows Unit sada ověřuje i skutečný ACL a junction v izolované fixture. Preflight vyžaduje Go: přes jeho `os/exec` skutečně spustí `pwsh` se stdin/stdout protokolem Terraform external provideru. Samotné spuštění přes .NET neověřuje vyhledání a spuštění programu v Go. Nefunkční alias oprav instalací funkčního PowerShell a jeho procesovým PATH.
- Pester spouštěj jen přes `tools/Invoke-Tests.ps1` (cílený běh přes `-Path`). Skript nastaví `Set-StrictMode -Version Latest` a verzi Pester z `tools/requirements.psd1`. Bez StrictMode test projde i při čtení nedefinované proměnné a v CI pak selže.
- Kroky CI, které `Invoke-LocalCi.ps1` nepokrývá, spouštěj příkazy z `.github/workflows/ci.yml` beze změny parametrů.
- Na CI čekej přes `./tools/Wait-PullRequestChecks.ps1 -Pr <číslo>`. Skript se vrátí nejpozději po `-MaxSeconds` (výchozí hodnota 230 s) s řádkem stavu checks a Copilot review. Návratové kódy: 0 prošlo, 1 selhalo, 2 stále běží, 3 chyba.

### Security checkpoint během implementace

Spouštěč: návrh bezpečnostní nebo identitní kontroly je hotový včetně testů, celá změna ještě ne. Checkpoint se týká validace vlastníka, instalace, oprávnění, hranic, revokace tokenu a mazání. Netýká se dokumentace ani refaktoringu beze změny chování.

- Implementátor spustí review subagenta s jiným modelem (Opus ↔ GPT Sol) a s čerstvým kontextem.
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

### Fakta a rozhodnutí

- Každý fakt o stavu musí mít označení: ověřený (čím), nahlášený (kým), nebo neověřený.
- Návrh agenta se bez schválení nesmí stát rozhodnutím. Agent musí vést rozhodnutí uživatele a zadavatele úkolu odděleně od vlastních návrhů.
- Důvod: při zkracování záznamů o práci se kvalifikace ztrácejí. „Neověřeno“ se změní na „ověřeno“ a neschválená výjimka se zapíše jako rozhodnutí.

### Strop Copilot code review

- PR smí mít nejvýš 2 kola Copilot code review.
- Po vyčerpání stropu agent opraví jen funkční a bezpečnostní nálezy.
- Ostatní nálezy (kvalita testů a fixtures, okrajové případy, kosmetika) agent zapíše jako follow-up do souvisejícího issue. Ve vlákně review odpoví odkazem na follow-up a vlákno vyřeší.

### Merge gate

Merge gate rozhoduje, zda PR splňuje podmínky pro merge. Nerozhoduje, zda agent smí mergovat: souhlas uživatele nebo mandát drží volající.

- Session před handoffem spustí `./tools/agents/Test-MergeGate.ps1 -Repository <owner/repo> -Pr <číslo> -ExpectedHeadSha <head SHA>` a vloží JSON verdikt do handoffu.
  - S verdiktem `pending` smí session předat práci jen kvůli `copilot-review-in-progress`. V ostatních případech čeká.
  - S verdiktem `fail` smí session předat práci jen kvůli `open-questions` nebo `workflow-permissions-changed`, protože o nich rozhoduje uživatel. Ostatní důvody opraví.
- Koordinátor mergeuje jen přes `./tools/agents/Invoke-GatedMerge.ps1 -Repository <owner/repo> -Pr <číslo> -ExpectedHeadSha <head SHA> -Reason <souhlas nebo mandát>`. Skript vždy vyhodnotí gate znovu a mergeuje jen při `pass` přes `--squash --match-head-commit`. Merge queue gate nepodporuje (`merge-queue-unsupported`), protože fronta by PR zamergovala později bez gate.
- Koordinátor spouští verzi z `origin/main`, aby větev nemohla oslabit vlastní gate. Do důvěryhodného dočasného adresáře rozbalí celé `tools/` z této revize (`git archive origin/main tools | tar -xf - -C <adresář>`), včetně přibaleného YAML parseru a jeho hashů. Samostatná kopie skriptů z `tools/agents/` tento runtime neobsahuje. Závislosti nesmí načítat z větve PR.
- Agent nesmí použít `gh pr merge --admin`, `--auto` ani `gh pr ready` a merge v jednom kroku. Verdikt `blocked-by-rules` znamená chybu v rulesetu, ne důvod k obejití pravidel.
- Změnu oprávnění tokenu (`permissions`), všech triggerů (`on`, události a jejich filtry), secrets (včetně `GITHUB_TOKEN` a `github.token`) nebo všech runnerů (`runs-on`, včetně GitHub-hosted) v `.github/workflows/**` nebo `.github/actions/**` musí potvrdit člověk pro konkrétní head SHA. G10 porovnává strukturu YAML z pevných base a head SHA, nikoli řádky patche. Nečitelný obsah, neplatný YAML a nepodporované anchors nebo aliasy vedou k `workflow-permissions-changed`. Koordinátor potvrzení předá přes `-AcknowledgeWorkflowChanges <head SHA>`.
- G4 páruje required status check podle `context` a případného `integration_id`. S `integration_id` ho splní jen check run se stejným `app.id`; commit status nestačí. Bez `integration_id` stačí shodné jméno.
- Konvence těla PR:
  - Tělo PR musí vždy obsahovat sekci `## Otevřené otázky`. Bez otázek obsahuje text „Žádné“. Neprázdná sekce zastaví merge (`open-questions`).
  - Sekce `## Otevřená živá kritéria` není otevřená otázka a gate ji nečte.
  - Sekce `## Rozhodnutí uživatele` (nebo `## Rozhodnutí pro uživatele`) bez ověřeného markeru přijetí vede k varování `decisions-unconfirmed`. Marker má tvar `<!-- merge-gate: decisions-accepted <login> <YYYY-MM-DD> -->`. G9 ověří login autora PR a všech editorů úplné neredigované historie těla proti loginu markeru. Nečitelná nebo nedočtená historie a jiný editor ponechají varování. Platí to i pro koordinátora; samostatný mandát nenahrazuje důkaz. Tento konzervativní důkaz odmítne i marker vložený uvedeným loginem po editaci jiného účtu.

## Jazyk

- Dokumentace, ADR, specifikace modulů a issues jsou česky podle skillu `controlled-czech`.
- Termíny jsou anglicky podle glosáře v `CONTEXT.md`. Český ekvivalent je v závorce u termínu.
- Kód, komentáře v kódu, názvy workflow a commit messages jsou anglicky.
