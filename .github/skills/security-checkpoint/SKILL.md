---
name: security-checkpoint
description: "Nezávisle ověř dokončený návrh bezpečnostní nebo identitní kontroly včetně testů podle AGENTS.md."
---

# Security checkpoint

Trigger a rozsah určuje sekce „Security checkpoint během implementace“
v `AGENTS.md`. Tento skill určuje provedení, ne další review každého ticketu.

1. Připrav pevný snapshot změny včetně testů a nových souborů. Použij zvolenou
   base revizi a zaznamenej SHA; neprováděj automatický fetch měnící sdílený ref
   během cizího gate. U necommitnutých změn předej neměnný diff snapshot.
2. Připoj zadání, přijatá rozhodnutí a odkazy na primární dokumentaci včetně
   verze každého externího API, které změna volá nebo mockuje. Zdůvodnění
   implementátora a jeho vlastní závěry reviewerovi nepředávej.
3. Vyber reviewera podle [model routingu](../../../docs/agents/model-routing.md).
   Ověř jinou modelovou rodinu než u implementátora a čerstvý kontext.
4. Spusť jednoho read-only review subagenta. Na pozadí pouze tehdy, když
   současně provádíš nezávislou práci; jinak počkej přímo. Použij notifikaci
   dokončení, nikoli modelovou polling smyčku. Reviewer už nedeleguje.
5. Zaznamenej report a dispozici každého nálezu: opraveno s regresním testem,
   zamítnuto s důkazem, nebo follow-up pro nesouvisející původní problém.
   Nález způsobený či zhoršený změnou musí být vyřešen před dokončením.

## Rozsah review

- Tvar externího API proti primární dokumentaci, včetně variant a fixtures.
- Fail-open stavy: prázdné, neznámé nebo nečitelné hodnoty nesmějí projít.
- Obnova po přerušení mezi zapisujícími kroky a její regresní testy.

Reviewer vrátí u nálezu závažnost, soubor a místo, scénář selhání, důkaz
a návrh opravy. Bez nálezu uvede ověřené oblasti. Neprovádí opravy ani publikaci.

## Výsledek

`running` není pass. `failed` znamená chybějící či neúplný report; oznam
blokaci a příčinu, neopakuj stejný nefunkční pokus bez nové informace.
`completed` vyžaduje report a dispozici všech nálezů.

Po změně kontrolovaného bezpečnostního chování ověř opravy a jejich dopady
nezávisle znovu. Rozsah opakování určují změněné podmínky, kontrakty a obnova,
nikoli počet řádků. Nová dokončená kontrola spouští checkpoint podle `AGENTS.md`.
Nezměněný snapshot s doloženým dokončeným checkpointem znovu neposílej.
