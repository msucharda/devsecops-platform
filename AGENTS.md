# Agent instructions

## Context pointers

Read only the branches relevant to the task. The linked documents are authoritative;
skills describe their own steps rather than restating shared policy.

| Trigger | Required source |
|---|---|
| Before design or implementation; when coordinating or resuming delivery | [Development workflow](docs/agents/development.md) |
| Before choosing a model or starting any session or subagent | [Model routing](docs/agents/model-routing.md) |
| Before domain exploration or recording terminology and decisions | [Domain documentation](docs/agents/domain.md) |
| Before reading or changing issues, specs, tickets or dependencies | [Issue tracker](docs/agents/issue-tracker.md) and [triage labels](docs/agents/triage-labels.md) |
| Before implementation or code review | [Coding standards](docs/agents/repository-rules.md#coding-standards), including security checkpoints and review requirements |
| Before tests, local gates or pushes; when changing or reviewing a runner | [Local CI](docs/agents/local-ci.md) |
| Before requesting Copilot review | [Review limit](docs/agents/repository-rules.md#strop-copilot-code-review) |
| Before PR publication, PR handoff or merge | [Merge gate](docs/agents/repository-rules.md#merge-gate), including PR body requirements |

Repository workflow skills live in `.github/skills`. The delivery entry point is
`/lever deliver #<spec>` from the installed lever plugin, under the development
workflow's repository contract. A skill or personal dial does not waive repository
gates, platform restrictions or the approved scope.

## Práce agentů

### Vlastnictví práce a delegování

Organizaci dodávky, limit implementátorů a předání určuje výhradně
[vývojový postup](docs/agents/development.md).
Subagent dostane ohraničený výsledek, potřebné zdroje a podmínku ukončení.
Zadavatel stejnou práci souběžně neopakuje. Krátké lookupy a jeden souvislý
průchod kódem řeší přímo.

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

## Code review

Before any code review, read the [review requirements](docs/agents/repository-rules.md#code-review)
and their coding standards. The `code-review` skill's Standards and Spec axes must
use that source even when no separate spec is available.

## Jazyk

- Instrukce skills, jejich metadata a profily agentů jsou anglicky. Toto pravidlo nemění jazyk rozhovoru ani výsledných dokumentů; doslovné nadpisy a jiné prvky šablon zachovávají jazyk výstupu.
- Dokumentace, ADR, specifikace modulů a issues jsou česky podle skillu `controlled-czech`.
- Termíny jsou anglicky podle glosáře v `CONTEXT.md`. Český ekvivalent je v závorce u termínu.
- Kód, komentáře v kódu, názvy workflow a commit messages jsou anglicky.
