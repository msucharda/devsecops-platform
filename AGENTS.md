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

CI workflow `Source CI` spouští dva joby navíc k Pester testům. Oba běží offline proti stubům a mají oprávnění jen `contents: read`.

#### Harness přerušení

- Job `Interruption harness` spouští testy s tagem `Interruption` ve 4 shardech (`INTERRUPTION_SHARD=<index>/4`). `tools/Invoke-Tests.ps1` bez parametru `-Tag` tyto testy vynechá. Lokální běh: `./tools/Invoke-Tests.ps1 -Tag Interruption`.
- Harness je v `tools/tests/InterruptionHarness.psm1`. `Invoke-InterruptionMatrix` spustí nástroj jednou a spočítá zapisující kroky. Pak pro každý krok spustí dvě varianty: `BeforeApply` (požadavek selže před zápisem) a `LoseResponse` (stub zápis provede a odpověď se ztratí). Po každém přerušení spustí nástroj znovu a vyžaduje:
  - opakovaný běh skončí úspěchem;
  - snapshot stavu stubu a lokálního stavu se rovná referenčnímu běhu;
  - žádné vytvoření objektu neproběhlo víckrát než v referenčním běhu.
- Nový nástroj, který mění stav, zapoj do harnessu takto:
  1. Ve stubu API pošli každý zapisující požadavek přes `Invoke-InterruptionStep`. U vytvoření, které API při opakování neodmítne, předej `-Identity`.
  2. Napiš `Reset` (počáteční stav stubu a lokálních souborů), `Run` a `Snapshot`. `Snapshot` vynechá hodnoty, které se mezi běhy legitimně liší (generovaná ID, časy).
  3. Přidej `Describe` s tagem `Interruption` a sharduj přes `Get-InterruptionShard`. Vzor: `tools/tests/GitHubBootstrap.Interruption.Tests.ps1`.

#### Mutační testy bezpečnostních kontrol

- Job `Security check mutation tests` spouští `tools/Invoke-MutationTests.ps1`. Skript oslabí každou označenou kontrolu a vyžaduje, aby pro každého mutanta selhal aspoň jeden test.
- Mutanti (mutants):
  - podmínka guardu s `throw`, `return $false`, `Write-Error` nebo `Exit-SetupStage` se změní na `$false` a na negaci;
  - podmínka s `continue` nebo `return $true` a logický `return` se změní na `$true` a na negaci;
  - každý operand `-or` v zamítací podmínce se změní na `$false`, každý operand `-and` v povolovací podmínce na `$true`;
  - case-sensitive operátor (`-ceq`, `-cne`, `-clike` a další) se změní na case-insensitive, pokud tím kontrola přijme víc hodnot.
- Novou bezpečnostní nebo identitní kontrolu označ takto:
  1. Na řádek přímo před funkci kontroly napiš `# security-check: <name>`. Název je kebab-case a je unikátní.
  2. Do `tools/tests/security-checks.psd1` přidej položku `Checks` s názvem a testy (`Path` a filtr `FullName`). Filtr porovnává nerozbalený název testu, tedy včetně `<Case>`.
  3. Lokálně spusť `./tools/Invoke-MutationTests.ps1 -Check <name>`.
- Přeživší mutant (survived) je chybějící negativní test. Doplň test. Výjimku v `Exceptions` přidej jen pro ekvivalentního mutanta, který nemůže změnit chování. Výjimka musí mít přesné ID mutanta z reportu, důvod a URL issue nebo PR.
- Běh selže při nesouladu markerů a konfigurace, při chybě baseline, při chybě mutanta, při přeživším mutantovi bez výjimky a při zastaralé výjimce.

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

## Jazyk

- Dokumentace, ADR, specifikace modulů a issues jsou česky podle skillu `controlled-czech`.
- Termíny jsou anglicky podle glosáře v `CONTEXT.md`. Český ekvivalent je v závorce u termínu.
- Kód, komentáře v kódu, názvy workflow a commit messages jsou anglicky.
